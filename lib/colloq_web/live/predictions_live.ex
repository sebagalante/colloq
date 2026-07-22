defmodule ColloqWeb.PredictionsLive do
  use ColloqWeb, :live_view

  alias Colloq.Repo
  alias Phoenix.PubSub

  # Point values live in Colloq.Predictions.Scorer (`weights/0`) — this module
  # used to carry its own unused copy describing a different ladder entirely.

  @impl true
  def mount(_params, _session, socket) do
    next_match = get_next_match()
    leaderboard = get_leaderboard()
    current_user = socket.assigns[:current_user]
    user_history = if current_user, do: get_user_history(current_user.id), else: []

    socket =
      socket
      |> assign(:page_title, gettext("Predictions"))
      |> assign(:next_match, next_match)
      |> assign(:leaderboard, leaderboard)
      |> assign(:user_history, user_history)
      |> assign(:form_home_score, "")
      |> assign(:form_away_score, "")
      |> assign(:form_first_scorer, "")
      |> assign(:form_motm, "")
      |> assign(:submitting, false)

    if connected?(socket) && next_match do
      PubSub.subscribe(Colloq.PubSub, "match:#{next_match.id}")
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("predict", %{
    "home_score" => home_score,
    "away_score" => away_score,
    "first_scorer" => first_scorer,
    "motm" => motm
  }, socket) do
    user = socket.assigns.current_user
    match = socket.assigns.next_match

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, gettext("You must log in to make predictions."))}

      is_nil(match) ->
        {:noreply, put_flash(socket, :error, gettext("There is no match open for predictions."))}

      # Re-check against the DB rather than trusting the assign: the match may
      # have kicked off since this client mounted, and a stale tab must not be
      # able to submit a prediction for a match in progress.
      not open_for_predictions?(match.fixture_id) ->
        {:noreply,
         socket
         |> assign(:next_match, nil)
         |> put_flash(:error, gettext("The match has started. No more predictions are accepted."))}

      true ->
        with {:ok, home} <- parse_score(home_score),
             {:ok, away} <- parse_score(away_score) do
          prediction = %{
            user_id: user.id,
            fixture_id: match.fixture_id,
            home_score: home,
            away_score: away,
            first_scorer: String.trim(first_scorer),
            motm: String.trim(motm)
          }

          case save_prediction(prediction) do
            {:ok, _} ->
              {:noreply,
               socket
               |> assign(:user_history, get_user_history(user.id))
               |> assign(:leaderboard, get_leaderboard())
               |> assign(:form_home_score, "")
               |> assign(:form_away_score, "")
               |> assign(:form_first_scorer, "")
               |> assign(:form_motm, "")
               |> put_flash(:info, gettext("Prediction saved!"))}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, reason)}
          end
        else
          :error ->
            {:noreply, put_flash(socket, :error, gettext("Goals must be valid numbers."))}
        end
    end
  end

  @impl true
  def handle_info({:match_started, _}, socket) do
    {:noreply, socket |> assign(:next_match, nil) |> put_flash(:info, gettext("The match has started. No more predictions are accepted."))}
  end

  def handle_info({:scores_updated, _}, socket) do
    {:noreply, socket |> assign(:leaderboard, get_leaderboard())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # Authoritative deadline: predictions close the moment the thread leaves
  # "prematch". Checked at submit time, not just when rendering the form.
  defp open_for_predictions?(nil), do: false

  defp open_for_predictions?(fixture_id) do
    import Ecto.Query

    Repo.exists?(
      from(t in Colloq.Forum.Topic,
        where:
          t.is_match_thread == true and t.match_id == ^fixture_id and t.match_mode == "prematch"
      )
    )
  end

  defp parse_score(str) do
    case Integer.parse(str) do
      {n, _} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Only prematch threads are open for predictions. "live" used to be included,
  # which meant anyone loading the page after kickoff got a prediction form for
  # a match already in progress — with the running score visible on the same
  # page. The {:match_started, _} handler only closes the form for clients
  # already connected, so it was never a real deadline.
  defp get_next_match do
    import Ecto.Query

    query =
      from(t in Colloq.Forum.Topic,
        where: t.is_match_thread == true,
        where: t.match_mode == "prematch",
        order_by: [desc: t.inserted_at],
        limit: 1
      )

    case Repo.all(query) do
      [] -> nil
      [topic | _] ->
        %{
          id: topic.id,
          fixture_id: topic.match_id,
          title: topic.title,
          home_team: topic.home_team || gettext("Home"),
          away_team: topic.away_team || gettext("Away"),
          # The template reads @next_match.match_date; a missing key raises
          # KeyError (not nil), so it must be present. Topics carry no kickoff
          # time yet, so it's nil and the date line stays hidden.
          match_date: nil
        }
    end
  end

  defp save_prediction(prediction) do
    import Ecto.Query

    # Check if user already predicted this match
    existing =
      Colloq.Predictions.Prediction
      |> where([p], p.user_id == ^prediction.user_id and p.fixture_id == ^prediction.fixture_id)
      |> Repo.one()

    schema = if existing, do: existing, else: struct!(Colloq.Predictions.Prediction)

    changeset =
      schema
      |> Ecto.Changeset.cast(prediction, [:user_id, :fixture_id, :home_score, :away_score, :first_scorer, :motm])
      |> Ecto.Changeset.validate_required([:home_score, :away_score])

    case Repo.insert_or_update(changeset) do
      {:ok, pred} -> {:ok, pred}
      {:error, _} -> {:error, gettext("Error saving the prediction.")}
    end
  end

  defp get_user_history(user_id) do
    import Ecto.Query

    query =
      from(p in Colloq.Predictions.Prediction,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at],
        limit: 20
      )

    Repo.all(query)
    |> Enum.map(fn p ->
      %{
        match_title: get_match_title(p.fixture_id),
        home_score: p.home_score,
        away_score: p.away_score,
        points: p.points || 0,
        inserted_at: p.inserted_at
      }
    end)
  end

  defp get_match_title(fixture_id) do
    Colloq.Forum.get_topic!(fixture_id).title
  rescue
    # get_topic!/1 raises on a missing topic; there is no nil return to match.
    _ -> gettext("Match #%{id}", id: fixture_id)
  end

  defp get_leaderboard do
    import Ecto.Query

    season_start = Date.new!(Date.utc_today().year - 1, 7, 1)

    query =
      from(p in Colloq.Predictions.Prediction,
        where: p.points > 0,
        group_by: p.user_id,
        select: %{
          user_id: p.user_id,
          total_points: sum(p.points),
          predictions_count: count(p.id)
        },
        order_by: [desc: sum(p.points)],
        limit: 20
      )

    entries =
      Repo.all(query)
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, rank} ->
        user = Colloq.Accounts.get_user(entry.user_id)
        streak = get_user_streak(entry.user_id)

        %{
          rank: rank,
          username: if(user, do: user.username, else: gettext("User #%{id}", id: entry.user_id)),
          points: entry.total_points,
          predictions: entry.predictions_count,
          streak: streak
        }
      end)

    entries
  end

  defp get_user_streak(user_id) do
    import Ecto.Query

    predictions =
      from(p in Colloq.Predictions.Prediction,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at],
        select: %{points: p.points},
        limit: 10
      )
      |> Repo.all()

    find_streak(predictions)
  end

  defp find_streak([]), do: 0
  defp find_streak([%{points: points} | rest]) when points > 0 do
    1 + find_streak(rest)
  end
  defp find_streak(_), do: 0
end
