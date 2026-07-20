defmodule Colloq.Workers.TopicSummarizerWorker do
  @moduledoc """
  LLM-based topic summarization worker.

  Generates a summary of the most recent posts in a topic
  using an LLM model and persists it on the topic (survives restarts;
  marked outdated when new posts arrive).

  The summary is displayed at the bottom of the topic as a
  dedicated section, similar to the Discourse style.
  """
  use Oban.Worker, queue: :llm, max_attempts: 3

  require Logger

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Llm

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

      provider = summarizer_provider()
      model = summarizer_model()

      if blank?(provider) or blank?(model) do
        Logger.warning("[TopicSummarizer] Provider/model no configurados — configuralos en Admin ▸ LLM / IA")
        ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "summary_failed", %{reason: :not_configured})
        {:discard, :not_configured}
      else
      case Llm.complete(provider, messages, %{model: model, temperature: 0.3, max_tokens: 1024}) do
        {:ok, %{content: summary}} ->
          generated_at = DateTime.utc_now()
          label = "#{provider} · #{model}"

          payload = %{
            summary: summary,
            generated_at: generated_at,
            model: label,
            post_number: topic.posts_count
          }

          # Persist so it survives restarts and can be marked outdated when new
          # posts arrive (posts_count is captured as summary_post_number).
          Forum.put_topic_summary(topic, %{
            summary: summary,
            model: label,
            generated_at: generated_at,
            post_number: topic.posts_count
          })

          ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "summary_ready", payload)

          Logger.info("[TopicSummarizer] Resumen generado para topic #{topic_id} (#{provider}/#{model})")
          :ok

        {:error, :rate_limited} ->
          {:snooze, 120}

        {:error, reason} ->
          Logger.warning("[TopicSummarizer] Error generando resumen para topic #{topic_id}: #{inspect(reason)}")

          # Tell the LiveView so the loading card resolves instead of spinning
          # forever. Config errors (missing key, bad model) won't fix on retry,
          # so discard rather than burn Oban attempts.
          ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "summary_failed", %{reason: reason})
          {:discard, reason}
      end
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

  @doc """
  Whether a summarizer provider *and* model are configured. When false, the UI
  should show a "not set up" message rather than enqueue a job that can't run.
  """
  def configured? do
    not blank?(summarizer_provider()) and not blank?(summarizer_model())
  end

  # Summarizer provider/model come ONLY from admin config (SiteSettings, then
  # optional env override). No hardcoded model — whatever you set is what runs.
  defp summarizer_provider do
    setting("summarizer_provider") || Application.get_env(:colloq, :summarizer_provider)
  end

  defp summarizer_model do
    setting("summarizer_model") || Application.get_env(:colloq, :summarizer_model)
  end

  defp setting(key) do
    case Colloq.SiteSettings.get(key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp blank?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")
end
