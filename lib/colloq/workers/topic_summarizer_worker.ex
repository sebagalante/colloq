defmodule Colloq.Workers.TopicSummarizerWorker do
  @moduledoc """
  LLM-based topic summarization worker.

  Generates a summary of the most recent posts in a topic
  using an LLM model and caches it in Cachex.

  The summary is displayed at the bottom of the topic as a
  dedicated section, similar to the Discourse style.
  """
  use Oban.Worker, queue: :llm, max_attempts: 3

  require Logger

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Llm

  @cache_ttl :timer.hours(4)
  @max_posts_for_summary 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"topic_id" => topic_id}}) do
    topic = Forum.get_topic!(topic_id)
    posts = get_recent_posts(topic_id)

    if length(posts) < 3 do
      {:discard, "muy pocos posts para resumir"}
    else
      posts_text = format_posts_for_llm(posts)

      messages = [
        %{
          role: "system",
          content: """
          Sos un asistente que resume conversaciones de un foro de fútbol argentino.
          Generá un resumen conciso y útil de la discusión.
          El resumen debe:
          - Destacar los puntos principales de la conversación
          - Mencionar opiniones o posturas relevantes de los usuarios
          - Ser en español rioplatense
          - Tener entre 3 y 5 párrafos cortos
          - No usar formato markdown excesivo
          """
        },
        %{
          role: "user",
          content: """
          Resumí esta conversación del tema "#{topic.title}":

          #{posts_text}
          """
        }
      ]

      provider = Application.get_env(:colloq, :summarizer_provider, "groq")
      model = Application.get_env(:colloq, :summarizer_model, "llama-3.1-8b-instant")

      case Llm.complete(provider, messages, %{model: model, temperature: 0.3, max_tokens: 1024}) do
        {:ok, %{content: summary}} ->
          cache_key = "summary:#{topic_id}"
          generated_at = DateTime.utc_now()
          Cachex.put(:forum_cache, cache_key, %{summary: summary, generated_at: generated_at}, ttl: @cache_ttl)

          ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "summary_ready", %{
            summary: summary,
            generated_at: generated_at
          })

          Logger.info("[TopicSummarizer] Resumen generado para topic #{topic_id}")
          :ok

        {:error, :rate_limited} ->
          {:snooze, 120}

        {:error, reason} ->
          Logger.warning("[TopicSummarizer] Error generando resumen para topic #{topic_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_recent_posts(topic_id) do
    import Ecto.Query

    from(p in Colloq.Forum.Post,
      where: p.topic_id == ^topic_id,
      where: is_nil(p.deleted_at),
      where: p.is_system == false,
      order_by: [desc: p.inserted_at],
      limit: @max_posts_for_summary,
      preload: [:user]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  defp format_posts_for_llm(posts) do
    Enum.map_join(posts, "\n\n", fn post ->
      username = if post.user, do: post.user.username, else: "anónimo"
      body = strip_html(post.body || "")
      "[#{username}]: #{body}"
    end)
  end

  defp strip_html(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end
end
