defmodule Colloq.Workers.ResultabotCommandWorker do
  @moduledoc """
  `/resultabot` command — starts ResultaBot's live coverage of a match.

  Coverage is started by hand, in the match thread itself, rather than by a
  scheduler: someone decides "we're covering this one" at kickoff. That keeps
  the bot silent on ordinary days and makes it impossible to start it anywhere
  except a match topic.

  Two guards, in this order:

    1. The caller must be staff (`:start_match_bot`) or listed in the
       `resultabot_operators` site setting.
    2. The topic must be a match thread with an external match id.

  Authorisation is checked first so an unauthorised user learns nothing about
  whether a topic is set up for coverage.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Colloq.{Accounts, Forum, Permissions, Repo, SiteSettings}
  alias Colloq.Workers.ScoreBotWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Forum.get_post!(post_id)
    topic = post.topic

    with :ok <- authorize(post.user),
         {:ok, match_id} <- match_thread(topic) do
      run(subcommand(post.body), topic, match_id)
    else
      {:error, :unauthorized} ->
        # Silent: no post, no hint. Anyone may type the command; only the
        # designated few get a response.
        Logger.info("[ResultaBot] /resultabot rechazado para user #{post.user_id}")
        :ok

      {:error, :not_match_thread} ->
        reply(topic, """
        <p>⚠️ Solo puedo cubrir partidos desde el hilo del partido. \
        Este tema no está marcado como hilo de partido.</p>
        """)

        :ok
    end
  end

  # --- Subcommands ---

  defp run(:start, topic, match_id) do
    # Mark the topic live before queueing: the poll checks this flag before
    # scheduling its successor, so coverage that starts "stopped" would die
    # after one tick.
    Forum.set_match_mode(topic, "live")
    ScoreBotWorker.start_polling(match_id, topic.id)

    reply(topic, """
    <p>📡 <strong>ResultaBot en vivo</strong> — sigo este partido y voy \
    publicando goles y tarjetas acá mismo.</p>
    """)

    Logger.info("[ResultaBot] cobertura iniciada en topic #{topic.id} (match #{match_id})")
    :ok
  end

  defp run(:stop, topic, match_id) do
    # Order matters: flip the flag FIRST. A poll executing right now will check
    # it before scheduling the next one, so the loop cannot outlive the stop.
    Forum.set_match_mode(topic, "fulltime")
    {:ok, cancelled} = Oban.cancel_all_jobs(polling_jobs(match_id))

    reply(topic, """
    <p>🛑 <strong>ResultaBot</strong> — corté la cobertura de este partido. \
    Para volver a arrancar, mandá <code>/resultabot</code>.</p>
    """)

    Logger.info("[ResultaBot] cobertura detenida en topic #{topic.id}: #{cancelled} job(s)")
    :ok
  end

  defp run(:status, topic, match_id) do
    pending = Repo.aggregate(polling_jobs(match_id), :count, :id)

    body =
      if pending > 0 do
        "<p>✅ <strong>ResultaBot</strong> — cobertura activa (partido <code>#{match_id}</code>).</p>"
      else
        "<p>💤 <strong>ResultaBot</strong> — no estoy siguiendo este partido. " <>
          "Mandá <code>/resultabot</code> para arrancar.</p>"
      end

    reply(topic, body)
    :ok
  end

  defp run({:unknown, word}, topic, _match_id) do
    reply(topic, """
    <p>🤔 No conozco <code>/resultabot #{word}</code>. Puedo: \
    <code>/resultabot</code> (arrancar), <code>/resultabot stop</code> (cortar), \
    <code>/resultabot status</code> (ver si estoy activo).</p>
    """)

    :ok
  end

  # Anything scheduled, waiting or running for this fixture. Matching on the
  # fixture rather than the topic means a stop also clears a loop left over
  # from an earlier attempt on the same match.
  defp polling_jobs(match_id) do
    from(j in Oban.Job,
      where: j.worker == "Colloq.Workers.ScoreBotWorker",
      where: j.state in ["available", "scheduled", "executing", "retryable"],
      where: fragment("? ->> 'fixture_id' = ?", j.args, ^to_string(match_id))
    )
  end

  # `/resultabot stop` used to *start* coverage: matching was prefix-only and
  # the argument was ignored — the worst possible failure for the one command
  # you reach for when something is going wrong mid-match.
  @doc false
  def subcommand(body) when is_binary(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.split(" ")
    |> case do
      ["/resultabot"] -> :start
      ["/resultabot", "stop" | _] -> :stop
      ["/resultabot", "parar" | _] -> :stop
      ["/resultabot", "status" | _] -> :status
      ["/resultabot", "estado" | _] -> :status
      ["/resultabot", word | _] -> {:unknown, word}
      _ -> :start
    end
  end

  def subcommand(_), do: :start

  # Staff by permission, plus any username listed in `resultabot_operators`
  # (comma-separated) so a trusted non-staff member can start coverage.
  defp authorize(nil), do: {:error, :unauthorized}

  defp authorize(%Accounts.User{} = user) do
    if Permissions.can?(user, :start_match_bot) or designated?(user) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp designated?(user) do
    case SiteSettings.get("resultabot_operators") do
      value when is_binary(value) ->
        value
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
        |> Enum.member?(String.downcase(user.username))

      _ ->
        false
    end
  end

  # A match id is required as well as the flag: the flag alone would start a
  # polling loop with nothing to poll.
  defp match_thread(%{is_match_thread: true, match_id: match_id})
       when is_binary(match_id) and match_id != "" do
    {:ok, match_id}
  end

  defp match_thread(_topic), do: {:error, :not_match_thread}

  defp reply(topic, body) do
    bot = ScoreBotWorker.bot_user()

    Forum.create_post(topic, bot, %{
      "body" => body,
      "is_system" => true,
      "system_type" => "bot_status"
    })
  end

  @doc """
  Whether a post body is the `/resultabot` command.

  Bodies are Tiptap HTML, so tags are stripped before matching — otherwise the
  body starts with `<p>`, not `/resultabot`.
  """
  def command?(body) when is_binary(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.trim()
    |> String.downcase()
    |> String.starts_with?("/resultabot")
  end

  def command?(_), do: false
end
