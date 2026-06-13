defmodule Colloq.Workers.LlmResponderWorker do
  @moduledoc """
  Worker de respuesta vía LLM cuando se menciona una persona bot.

  Carga la persona bot desde la tabla bot_system, construye el prompt
  del sistema y el array de mensajes, llama al proveedor LLM configurado
  y publica la respuesta como post del bot en el mismo hilo.
  """
  use Oban.Worker, queue: :llm, max_attempts: 3

  require Logger

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Bots.BotSystem
  alias Colloq.Llm
  alias Colloq.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id, "persona_slug" => persona_slug}}) do
    post = Forum.get_post!(post_id)
    persona = Repo.get_by!(BotSystem, slug: persona_slug, type: "persona", active: true)

    topic = post.topic
    bot_config = persona.config || %{}
    provider = Map.get(bot_config, "provider", "openrouter")
    model = Map.get(bot_config, "model", "openai/gpt-4o-mini")

    messages = build_messages(persona, post, topic, bot_config)

    case Llm.complete(provider, messages, %{model: model}) do
      {:ok, %{content: reply_body}} ->
        bot_user = Repo.get_by!(Colloq.Accounts.User, username: persona_slug)

        {:ok, _reply_post} =
          Forum.create_post(topic, bot_user, %{
            "body" => reply_body,
            "body_json" => nil
          })

        :ok

      {:error, :rate_limited} ->
        {:snooze, 60}

      {:error, reason} ->
        Logger.warning("LLM responder falló para #{persona_slug}: #{inspect(reason)}")
        {:error, reason}
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
    persona_personality = Map.get(bot_config, "personality", "Sos un asistente útil y amable.")

    """
    #{persona_personality}

    Tu nombre de usuario es @#{persona.slug} y tu nombre mostrado es "#{persona_name}".
    Estás participando en un foro de fútbol argentino llamado Colloq.
    Respondé de manera natural, como un hincha más. No uses formato markdown excesivo.
    Mantené la conversación en español rioplatense.
    No reveles que sos una IA bajo ninguna circunstancia.
    No repitas lo que ya dijeron otros usuarios. Aportá valor a la conversación.
    """
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
