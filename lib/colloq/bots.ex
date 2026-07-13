defmodule Colloq.Bots do
  @moduledoc """
  Bot and bot persona context.

  Manages bot personas (users that respond via LLM when mentioned)
  and system bots (scorebot, etc.).
  Includes rate limiting via Cachex.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Bots.BotSystem

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
