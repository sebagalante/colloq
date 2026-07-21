defmodule Colloq.Workers.LlmResponderWorker do
  @moduledoc """
  LLM response worker for bot persona mentions.

  Loads the bot persona from the bot_system table, builds the system
  prompt and message array, calls the configured LLM provider,
  and posts the response as a bot post in the same thread.
  """
  use Oban.Worker, queue: :llm, max_attempts: 3

  require Logger

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Bots.BotSystem
  alias Colloq.Llm
  alias Colloq.Accounts
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id, "persona_slug" => persona_slug}}) do
    post = Forum.get_post!(post_id)
    persona = Repo.get_by!(BotSystem, slug: persona_slug, type: "persona", active: true)

    topic = post.topic
    bot_config = persona.config || %{}
    provider = Map.get(bot_config, "provider", "openrouter")

    model =
      bot_config
      |> Map.get("model", "openai/gpt-4o-mini")
      |> maybe_web_search(provider, bot_config)

    messages = build_messages(persona, post, topic, bot_config)

    # Left at Llm's 1024 default, replies were coming back cut mid-sentence.
    # Reasoning models spend part of this budget before writing a word, so the
    # visible answer can end up far shorter than the number suggests.
    max_tokens = int_config(bot_config, "max_tokens", 2048)

    case Llm.complete(provider, messages, %{model: model, max_tokens: max_tokens}) do
      {:ok, %{content: reply_body} = response} ->
        if response[:finish_reason] == "length" do
          Logger.warning(
            "LLM responder: respuesta truncada por max_tokens (#{max_tokens}) " <>
              "para #{persona_slug}. Subí max_tokens en la config del bot."
          )
        end

        case Repo.get_by(Colloq.Accounts.User, username: persona_slug) do
          nil ->
            Logger.warning("LLM responder: no existe usuario para persona #{persona_slug}")
            {:error, "bot user not found"}

          bot_user ->
            {:ok, _reply_post} =
              Forum.create_post(topic, bot_user, %{
                "body" => reply_body,
                "body_json" => nil
              })

            :ok
        end

      {:error, :rate_limited} ->
        {:snooze, 60}

      {:error, reason} ->
        Logger.warning("LLM responder falló para #{persona_slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Web search is provider-specific. OpenRouter runs a live search when the
  # model is suffixed with ":online"; other providers have no equivalent here,
  # so the toggle is a no-op for them.
  defp maybe_web_search(model, "openrouter", bot_config) do
    if Map.get(bot_config, "web_search") == true and not String.ends_with?(model, ":online") do
      model <> ":online"
    else
      model
    end
  end

  defp maybe_web_search(model, _provider, _bot_config), do: model

  # The admin bot form saves the prompt under "system_prompt", but this worker
  # only ever read "personality" — so every prompt written through the UI was
  # silently dropped and the bot answered with the generic fallback below.
  # "personality" is still honoured for rows created before the form existed.
  defp persona_prompt(bot_config) do
    presence(bot_config["system_prompt"]) || presence(bot_config["personality"]) ||
      "Sos un asistente útil y amable."
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # Bot config comes from JSON, so a number may arrive as a string.
  defp int_config(config, key, default) do
    case Map.get(config, key) do
      n when is_integer(n) and n > 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp build_messages(persona, trigger_post, topic, bot_config) do
    system_prompt = build_system_prompt(persona, bot_config)

    context_messages = fetch_recent_posts(topic, trigger_post)

    system_prompt = system_prompt <> "\n\nContexto del hilo:\nTítulo: #{topic.title}\n\n---\n#{context_messages}\n---"

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "@#{persona.slug} #{strip_mentions(trigger_post.body)}"}
    ]
  end

  defp build_system_prompt(persona, bot_config) do
    persona_name = Map.get(bot_config, "display_name", persona.name)
    persona_personality = persona_prompt(bot_config)

    """
    #{persona_personality}

    Tu nombre de usuario es @#{persona.slug} y tu nombre mostrado es "#{persona_name}".
    Estás participando en un foro de fútbol argentino llamado Colloq.
    Respondé de manera natural. No uses formato markdown excesivo.
    Mantené la conversación en español rioplatense.
    #{ai_disclosure_line(bot_config)}
    No repitas lo que ya dijeron otros usuarios. Aportá valor a la conversación.
    """
  end

  # Assistant-style bots (`disclose_ai: true`) should own up to being a bot when
  # asked — instructing an assistant to deny it would just be deceiving users.
  # Existing character personas keep their previous behaviour by default.
  defp ai_disclosure_line(bot_config) do
    if Map.get(bot_config, "disclose_ai") == true do
      "Sos un asistente de IA. Si te preguntan, decilo con naturalidad, sin vueltas."
    else
      "No reveles que sos una IA bajo ninguna circunstancia."
    end
  end

  defp fetch_recent_posts(topic, _trigger_post) do
    query =
      Ecto.Query.from(
        p in Colloq.Forum.Post,
        where: p.topic_id == ^topic.id,
        where: is_nil(p.deleted_at),
        order_by: [desc: p.inserted_at],
        limit: 20,
        preload: [:user]
      )

    Repo.all(query)
    |> Enum.reverse()
    |> Enum.map(fn p ->
      "#{p.user.username}: #{strip_html(p.body)}"
    end)
    |> Enum.join("\n")
  end

  defp strip_mentions(body) do
    String.replace(body, ~r/@[a-zA-Z0-9_]+/, "")
    |> String.trim()
  end

  defp strip_html(body) do
    body
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&[^;]+;/, "")
    |> String.trim()
  end
end
