defmodule Colloq.Workers.ScoreBotWorker do
  @moduledoc """
  Match day score bot worker — the heart of the live match experience.

  Cron: 9:00 AM daily → fixture preview post.
  During match: polls API-Football every 90s for live events.
  On FT: posts match summary, triggers PredictionScorerWorker and PushNotificationWorker.
  Broadcasts {:match_mode_changed, topic_id, mode} and {:match_event, topic_id, data} via PubSub.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 5
  import Ecto.Query
  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic

  defp api_base, do: Application.get_env(:colloq, :api_football_url, "https://v3.football.api-sports.io")

  @impl Oban.Worker
  def perform(%{args: %{"action" => "preview"}}) do
    match_threads = Repo.all(
      from(t in Topic, where: t.is_match_thread == true and t.match_mode == "prematch")
    )

    Enum.each(match_threads, fn topic ->
      create_preview_post(topic)
    end)

    {:ok, length(match_threads)}
  end

  @impl Oban.Worker
  def perform(%{args: %{"action" => "poll", "fixture_id" => fixture_id, "topic_id" => topic_id}}) do
    topic = Forum.get_topic!(String.to_integer(topic_id))

    case fetch_live_events(fixture_id) do
      {:ok, events} ->
        Enum.each(events, fn event ->
          create_event_post(topic, event)
          broadcast_event(topic.id, event)
        end)
        {:ok, length(events)}

      {:error, :not_live} ->
        transition_to_fulltime(topic)
        {:ok, :transitioned_to_ft}

      {:error, reason} ->
        {:snooze, 30}
    end
  end

  def perform(%{args: %{"action" => "ft_summary", "fixture_id" => fixture_id, "topic_id" => topic_id}}) do
    topic = Forum.get_topic!(topic_id)

    # Post match summary
    body = build_ft_summary(fixture_id)
    system_user = get_or_create_scorebot_user()
    Forum.create_post(topic, system_user, %{"body" => body, "is_system" => true, "system_type" => "summary"})

    # Transition to fulltime mode
    Forum.set_match_mode(topic, "fulltime")
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "match_mode_changed", %{mode: "fulltime"})

    # Trigger scoring
    Colloq.Workers.PredictionScorerWorker.new(%{fixture_id: fixture_id, topic_id: topic_id})
    |> Oban.insert()

    {:ok, :summary_posted}
  end

  # --- API call ---

  defp fetch_live_events(fixture_id) do
    key = Application.get_env(:colloq, :api_football_key)

    case Req.get("#{api_base()}/fixtures/events",
           params: [fixture: fixture_id],
           headers: %{"x-rapidapi-key" => key, "x-rapidapi-host" => "v3.football.api-sports.io"},
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"response" => events}}} ->
        match_status = get_fixture_status(fixture_id)
        if match_status in ["1H", "2H", "HT", "ET", "P"] do
          {:ok, parse_events(events)}
        else
          {:error, :not_live}
        end

      {:ok, %{status: code}} ->
        {:error, "API returned #{code}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_fixture_status(fixture_id) do
    key = Application.get_env(:colloq, :api_football_key)

    case Req.get("#{api_base()}/fixtures",
           params: [id: fixture_id],
           headers: %{"x-rapidapi-key" => key, "x-rapidapi-host" => "v3.football.api-sports.io"},
           receive_timeout: 5_000
         ) do
      {:ok, %{status: 200, body: %{"response" => [fixture | _]}}} ->
        fixture["fixture"]["status"]["short"]

      _ ->
        "NS"
    end
  end

  # --- Event parsing ---

  defp parse_events(events) do
    events
    |> Enum.map(fn e ->
      %{
        type: e["type"],
        player: e["player"]["name"],
        assist: e["assist"]["name"],
        minute: e["time"]["elapsed"],
        detail: e["detail"],
        team: e["team"]["name"]
      }
    end)
    |> Enum.uniq_by(&{&1.type, &1.player, &1.minute})
  end

  # --- Post creation ---

  defp create_preview_post(topic) do
    system_user = get_or_create_scorebot_user()
    body = "Fixture ID: #{topic.match_id}"
    Forum.create_post(topic, system_user, %{
      "body" => "⚽ Vista previa del partido",
      "is_system" => true,
      "system_type" => "preview"
    })
  end

  defp create_event_post(topic, event) do
    system_user = get_or_create_scorebot_user()

    {type_label, body} =
      case event.type do
        "Goal" ->
          scorer = event.player
          assist = if event.assist, do: " (asist. #{event.assist})", else: ""
          {"goal", "⚽ ¡GOOOL! #{scorer} #{event.minute}'#{assist}"}

        "Card" ->
          color = if String.contains?(event.detail, "Yellow"), do: "🟨", else: "🟥"
          {"card", "#{color} #{color == "🟨" && "Amarilla" || "Tarjeta roja"} — #{event.player} #{event.minute}'"}

        "subst" ->
          {"sub", "🔄 Cambio: #{event.player} #{event.minute}' — #{event.detail}"}

        _ ->
          {"event", "#{event.type}: #{event.player} #{event.minute}'"}
      end

    Forum.create_post(topic, system_user, %{
      "body" => body,
      "is_system" => true,
      "system_type" => type_label,
      "event_data" => event
    })
  end

  defp build_ft_summary(_fixture_id) do
    # TODO: fetch actual fixture data to build summary
    "⚡ ¡Final del partido!"
  end

  # --- PubSub ---

  defp broadcast_event(topic_id, event) do
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic_id}", "match_event", %{
      type: event.type,
      player: event.player,
      minute: event.minute,
      detail: event.detail,
      team: event.team
    })
  end

  defp transition_to_fulltime(topic) do
    Forum.set_match_mode(topic, "fulltime")
    ColloqWeb.Endpoint.broadcast("forum:topic:#{topic.id}", "match_mode_changed", %{mode: "fulltime"})
  end

  # --- System user ---

  defp get_or_create_scorebot_user do
    case Colloq.Accounts.get_user_by_username("scorebot") do
      nil ->
        {:ok, user} = Colloq.Accounts.register_bot(%{
          email: "scorebot@colloq.local",
          username: "scorebot",
          display_name: "ScoreBot",
          password: "scorebot-internal",
          password_confirmation: "scorebot-internal"
        })
        user

      user ->
        user
    end
  end
end