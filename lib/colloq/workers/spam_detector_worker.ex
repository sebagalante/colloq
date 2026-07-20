defmodule Colloq.Workers.SpamDetectorWorker do
  @moduledoc """
  Spam detection worker for new posts.

  Enqueued when a TL0 or TL1 user creates a post. System posts and bot accounts
  are never screened.

  Checks multiple signals:
    - Blocked words from SiteSettings
    - Optional fallback: LLM classifier via Groq for borderline cases

  Duplicate content is *not* checked here. It is refused at submission time by
  `Colloq.Forum.create_post/3` inside a short window, so the author is told
  immediately instead of having the post accepted and then hidden.

  There is deliberately **no link limit**, at any trust level. This is a
  football forum: fans post highlights, tweets and stat pages by the handful,
  and a URL count flagged ordinary members as spammers. Link spam has to be
  caught by the blocked-word list or the classifier, on what the links *are*,
  not how many there are.

  If spam is detected: hides the post, flags it, and notifies the author.

  ## ML classifier (optional, runs after the cheap heuristics)

  When `spam_ml_enabled` is on, a post that passes the rule checks is sent to a
  local ONNX spam classifier (see `Colloq.SpamClassifier` + the `spam_classifier/`
  sidecar). Behaviour is controlled by site settings, all fail-open:

    * `spam_ml_enabled`   — boolean, default off
    * `spam_ml_mode`      — "shadow" (log only) | "enforce", default "shadow"
    * `spam_ml_threshold` — spam-probability cutoff, default 0.9
    * `spam_ml_url`       — sidecar base URL (also read by SpamClassifier)

  Shadow mode logs `{post_id, score, would_flag}` and takes no action — ship in
  shadow first, read the score distribution, then flip to enforce.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  alias Colloq.Repo
  alias Colloq.Forum.Post
  alias Colloq.Moderation
  alias Colloq.Notifications
  alias Colloq.SiteSettings
  alias Colloq.SpamClassifier

  import Ecto.Query
  require Logger

  @default_ml_threshold 0.9

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Repo.get!(Post, post_id) |> Repo.preload(:user)

    user = post.user

    # Second line of defence: jobs already queued before the caller-side skip
    # existed, or enqueued by any other path, must not hide a bot's own reply.
    cond do
      post.is_system or user.flair == "BOT" ->
        {:discard, "post de sistema/bot — sin screening"}

      user.trust_level not in [0, 1] ->
        {:discard, "TL#{user.trust_level} — no verificado"}

      true ->
        run_classification(post)
    end
  end

  defp run_classification(post) do
    case classify(post) do
      :ok -> :ok
      {:spam, reason} -> handle_spam(post, reason)
    end
  end

  defp classify(post) do
    cond do
      contains_blocked_words?(post.body) ->
        {:spam, "palabras_bloqueadas"}

      # Cheap heuristics passed — fall back to the ML classifier if enabled.
      true ->
        ml_classify(post)
    end
  end

  # --- ML classifier step ----------------------------------------------------

  defp ml_classify(post) do
    if ml_enabled?() do
      text = post.body |> to_string() |> HtmlSanitizeEx.strip_tags() |> String.trim()

      case SpamClassifier.classify(text) do
        {:ok, %{score: score}} ->
          decide(post, score)

        # Fail-open: never lose a legit post because the model is unreachable.
        {:error, reason} ->
          Logger.warning("[SpamDetector] ML classifier unavailable, allowing post ##{post.id} (#{inspect(reason)})")
          :ok
      end
    else
      :ok
    end
  end

  defp decide(post, score) do
    threshold = ml_threshold()
    mode = ml_mode()
    would_flag = score >= threshold

    Logger.info(
      "[SpamDetector] ml post=#{post.id} score=#{Float.round(score, 4)} " <>
        "threshold=#{threshold} would_flag=#{would_flag} mode=#{mode}"
    )

    if would_flag and mode == "enforce" do
      {:spam, "ml_classifier:#{Float.round(score, 3)}"}
    else
      # Shadow mode, or below threshold → observe only, take no action.
      :ok
    end
  end

  defp ml_enabled?, do: SiteSettings.get("spam_ml_enabled") == true

  defp ml_mode do
    case SiteSettings.get("spam_ml_mode") do
      "enforce" -> "enforce"
      _ -> "shadow"
    end
  end

  defp ml_threshold do
    case SiteSettings.get("spam_ml_threshold") do
      n when is_float(n) -> n
      n when is_integer(n) -> n * 1.0
      n when is_binary(n) -> parse_threshold(n)
      _ -> @default_ml_threshold
    end
  end

  defp parse_threshold(str) do
    case Float.parse(str) do
      {f, _} when f > 0.0 and f <= 1.0 -> f
      _ -> @default_ml_threshold
    end
  end

  defp contains_blocked_words?(body) when is_nil(body), do: false
  defp contains_blocked_words?(body) do
    words = load_blocked_words()
    body_downcase = String.downcase(body)

    Enum.any?(words, fn w ->
      String.contains?(body_downcase, String.downcase(w))
    end)
  end

  defp load_blocked_words do
    case SiteSettings.get("blocked_words") do
      nil -> []
      words when is_binary(words) -> String.split(words, ",", trim: true) |> Enum.map(&String.trim/1)
      words when is_list(words) -> words
    end
  end

  defp handle_spam(post, reason) do
    Logger.info("[SpamDetector] Spam detectado en post ##{post.id}: #{reason}")

    Moderation.hide_post(post)
    Moderation.flag_post(post.id, find_system_user_id(), "spam")

    Notifications.create_notification(%{
      type: "system",
      title: "Post ocultado por spam",
      # The motive leads: it's the one piece the reader actually needs, and
      # trailing it behind a sentence of preamble meant it was the first thing
      # clipped in the notification list.
      body:
        "Motivo: #{reason_text(reason)}. Se ocultó automáticamente por el sistema " <>
          "de detección de spam. Si creés que fue un error, contactá a un moderador.",
      user_id: post.user_id,
      # Raw code kept in data for moderation/debugging; the body carries prose.
      data: %{post_id: post.id, reason: reason}
    })

    {:ok, "spam detectado: #{reason}"}
  end

  # Reason codes are internal identifiers ("contenido_duplicado",
  # "ml_classifier:0.94"). Users saw them raw; these are what the codes mean.
  #
  # No longer emitted — the link-count rule was dropped, since a football forum
  # runs on shared highlights, tweets and stats and counting URLs flagged
  # ordinary fans. Kept so notifications sent before that still read properly.
  defp reason_text("exceso_de_links"), do: "el post tenía demasiados enlaces"

  defp reason_text("contenido_duplicado"),
    do: "ya habías publicado un texto idéntico hace poco"

  defp reason_text("palabras_bloqueadas"), do: "el texto contiene palabras bloqueadas"

  defp reason_text("ml_classifier:" <> score),
    do: "el clasificador automático lo marcó como spam (puntaje #{score})"

  # Unknown code: show it rather than swallowing it — an opaque motive still
  # beats no motive when someone asks a moderator about it.
  defp reason_text(other), do: to_string(other)

  defp find_system_user_id do
    case Colloq.Accounts.get_user_by_username("sistema") do
      nil -> 1
      user -> user.id
    end
  end
end
