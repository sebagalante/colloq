defmodule Colloq.Bots do
  @moduledoc """
  Bot and bot persona context.

  Manages bot personas (users that respond via LLM when mentioned)
  and system bots (scorebot, etc.).
  Includes rate limiting via Cachex.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Bots.BotSystem

  @doc """
  Ensures a forum `User` exists for a bot persona.

  This is the link the whole mention flow depends on: `MentionTriggerWorker`
  looks the mention up with `get_user_by_username/1`, and `LlmResponderWorker`
  posts the reply *as* that user. Without it a bot can never be @mentioned or
  reply (the worker logs "no existe usuario para persona").

  The username must equal the persona slug. Creates the account on first call,
  and keeps display name / avatar in sync afterwards. The password is random —
  the account exists only to author posts, never to log in.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def ensure_bot_user(%BotSystem{} = persona) do
    avatar =
      case Map.get(persona.config || %{}, "avatar_url") do
        url when is_binary(url) and url != "" -> url
        _ -> nil
      end

    case Repo.get_by(User, username: persona.slug) do
      nil -> create_bot_user(persona, avatar)
      user -> sync_bot_user(user, persona, avatar)
    end
  end

  defp create_bot_user(persona, avatar) do
    %User{}
    |> User.registration_changeset(%{
      username: persona.slug,
      email: "#{persona.slug}@bots.colloq.local",
      display_name: persona.name,
      password: random_password()
    })
    # Bots start at full trust: they're system accounts, not people earning
    # standing. TL2 was chosen only to dodge the TL0/TL1 spam cohort, which left
    # them short of can_edit_posts/can_upload_images and on a tag cap. The BOT
    # flair makes it visible that the author isn't a person, and is what
    # excludes them from spam screening and trust promotion.
    |> Ecto.Changeset.change(%{trust_level: 4, flair: "BOT", avatar_url: avatar})
    |> Repo.insert()
  end

  defp sync_bot_user(user, persona, avatar) do
    attrs = %{display_name: persona.name, flair: "BOT"}
    attrs = if avatar, do: Map.put(attrs, :avatar_url, avatar), else: attrs

    user |> User.update_changeset(attrs) |> Repo.update()
  end

  defp random_password, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Gets a bot persona by its slug.
  """
  def get_persona_by_slug(slug) do
    Repo.get_by(BotSystem, slug: slug, type: "persona")
  end

  @doc """
  Lists all active bot personas.
  """
  def list_personas do
    BotSystem
    |> where(type: "persona")
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Lists all system bots.
  """
  def list_system_bots do
    BotSystem
    |> where(type: "system")
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Checks the rate limit for a bot persona per user.

  Uses Cachex to maintain an invocation counter per persona+user.
  Returns :ok if within the limit, {:error, :rate_limited} if not.

  Default limit: 5 invocations per minute.
  """
  def check_rate_limit(persona_slug, user_id) do
    max_calls = Application.get_env(:colloq, :bot_rate_limit, 5)
    window_seconds = Application.get_env(:colloq, :bot_rate_window, 60)

    cache_key = "bot_rate:#{persona_slug}:#{user_id}"

    case Cachex.get(:forum_cache, cache_key) do
      {:ok, nil} ->
        Cachex.put(:forum_cache, cache_key, 1, ttl: :timer.seconds(window_seconds))
        :ok

      {:ok, count} when count < max_calls ->
        Cachex.incr(:forum_cache, cache_key)
        :ok

      {:ok, _count} ->
        {:error, :rate_limited}

      {:error, _} ->
        :ok
    end
  end
end
