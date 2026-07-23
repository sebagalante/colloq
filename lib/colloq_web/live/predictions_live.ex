defmodule ColloqWeb.PredictionsLive do
  use ColloqWeb, :live_view

  alias Colloq.{Predictions, Sofascore}

  # Point values live in Colloq.Predictions.Scorer (`weights/0`).

  @impl true
  def mount(_params, _session, socket) do
    season_id = Sofascore.current_season_id()

    socket =
      socket
      |> assign(:page_title, pgettext("prode", "Predictions"))
      |> assign(:season_id, season_id)

    socket =
      if season_id do
        load_round(socket, Sofascore.current_round())
      else
        assign(socket, round: nil, matches: [], predictions: %{}, leaderboard: [], next_available?: false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("nav-round", %{"dir" => dir}, socket) do
    delta = if dir == "next", do: 1, else: -1
    round = max(1, (socket.assigns.round || 1) + delta)
    {:noreply, load_round(socket, round)}
  end

  def handle_event("save-round", params, socket) do
    cond do
      is_nil(socket.assigns[:current_user]) ->
        {:noreply, put_flash(socket, :error, gettext("You must log in to make predictions."))}

      is_nil(socket.assigns.season_id) ->
        {:noreply, socket}

      true ->
        entries = collect_entries(params, socket.assigns.matches)

        case Predictions.upsert_round(
               socket.assigns.current_user.id,
               socket.assigns.season_id,
               socket.assigns.round,
               entries
             ) do
          {:ok, 0} ->
            {:noreply,
             put_flash(socket, :info, gettext("No open matches to save. Kickoff has passed."))}

          {:ok, count} ->
            {:noreply,
             socket
             |> load_round(socket.assigns.round)
             |> put_flash(:info, gettext("%{count} predictions saved!", count: count))}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Round loading
  # ---------------------------------------------------------------------------

  defp load_round(socket, round) do
    matches = fetch_matches(round)

    # Cap forward navigation at the last defined fecha: Sofascore only publishes
    # the Clausura a few rounds ahead, so without this "Siguiente" walks into a
    # dozen "no definida" pages and reads as broken. `fetch_matches/1` is
    # cache-backed (10 min), so this peek is cheap.
    next_available? = fetch_matches(round + 1) != []

    predictions =
      case socket.assigns[:current_user] do
        nil -> %{}
        user -> Predictions.for_user_round(user.id, socket.assigns.season_id, round)
      end

    socket
    |> assign(:round, round)
    |> assign(:matches, matches)
    |> assign(:next_available?, next_available?)
    |> assign(:predictions, predictions)
    |> assign(:leaderboard, Predictions.leaderboard(season: socket.assigns.season_id, limit: 20))
  end

  # Fetches the fecha and normalises each event into the view shape. Trims the
  # Apertura/Clausura round-number collision two ways: `current_phase/1` keeps
  # the nearest cluster, and the active-window filter drops a round whose only
  # matches belong to the previous tournament (so it reads as "not defined yet"
  # rather than showing months-old results). Sorted by kickoff.
  defp fetch_matches(round) do
    case Sofascore.round_fixtures(round) do
      {:ok, events} ->
        events
        |> Sofascore.current_phase()
        |> Enum.map(&to_match/1)
        |> Enum.filter(&within_active_window?/1)
        |> Enum.sort_by(& &1.kickoff_ts)
        |> lock_from_first_kickoff()

      _ ->
        []
    end
  end

  # Classic Prode deadline: the whole fecha closes the moment its first match
  # kicks off — one deadline for the round, not a per-match trickle. A finished
  # match stays locked regardless (it always sits after the first kickoff).
  defp lock_from_first_kickoff([]), do: []

  defp lock_from_first_kickoff(matches) do
    now = System.system_time(:second)

    first_kickoff =
      matches
      |> Enum.map(& &1.kickoff_ts)
      |> Enum.filter(&(&1 > 0))
      |> Enum.min(fn -> nil end)

    fecha_started? = is_integer(first_kickoff) and now >= first_kickoff

    Enum.map(matches, fn m -> %{m | locked?: fecha_started? or m.status == "finished"} end)
  end

  defp within_active_window?(%{kickoff_ts: ts}) when is_integer(ts) and ts > 0 do
    abs(ts - System.system_time(:second)) <= Sofascore.fixture_window_days() * 86_400
  end

  defp within_active_window?(_), do: false

  defp to_match(event) do
    status = get_in(event, ["status", "type"])
    ts = event["startTimestamp"]

    %{
      fixture_id: to_string(event["id"]),
      home: get_in(event, ["homeTeam", "name"]) || "?",
      away: get_in(event, ["awayTeam", "name"]) || "?",
      home_id: get_in(event, ["homeTeam", "id"]),
      away_id: get_in(event, ["awayTeam", "id"]),
      kickoff_ts: ts || 0,
      kickoff_label: kickoff_label(ts),
      status: status,
      # Once a match has finished, Sofascore keeps the score in the round payload.
      home_score: get_in(event, ["homeScore", "current"]),
      away_score: get_in(event, ["awayScore", "current"]),
      # Provisional lock; `lock_from_first_kickoff/1` finalises it for the whole
      # fecha. A finished match is always locked. Enforced again server-side in
      # `collect_entries/2`.
      locked?: status == "finished"
    }
  end

  defp kickoff_label(nil), do: "--"

  defp kickoff_label(ts) do
    ts
    |> DateTime.from_unix!(:second)
    |> DateTime.shift_zone!("America/Argentina/Buenos_Aires")
    |> Calendar.strftime("%d/%m %H:%M")
  rescue
    _ -> "--"
  end

  # Pulls home_<id>/away_<id> pairs from the form, keeping only open matches
  # with two valid non-negative integers.
  defp collect_entries(params, matches) do
    matches
    |> Enum.reject(& &1.locked?)
    |> Enum.flat_map(fn m ->
      with {:ok, home} <- parse_score(params["home_#{m.fixture_id}"]),
           {:ok, away} <- parse_score(params["away_#{m.fixture_id}"]) do
        [%{fixture_id: m.fixture_id, home_score: home, away_score: away}]
      else
        _ -> []
      end
    end)
  end

  defp parse_score(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {n, ""} when n >= 0 and n <= 99 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_score(_), do: :error

  # ---------------------------------------------------------------------------
  # Template helpers
  # ---------------------------------------------------------------------------

  @doc false
  def score_cell(nil), do: "–"
  def score_cell(n), do: n

  @doc false
  # Sofascore team crest. Nil id → nil src so the <img> is skipped entirely.
  def crest(nil), do: nil
  def crest(team_id), do: "https://api.sofascore.com/api/v1/team/#{team_id}/image"

  @doc false
  def match_state_label("finished"), do: gettext("Final")
  def match_state_label("inprogress"), do: gettext("Live")
  def match_state_label(_), do: gettext("Started")
end
