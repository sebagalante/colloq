defmodule Colloq.Predictions.PredictionsLive do
  use ColloqWeb, :live_view

  alias Colloq.Repo
  alias Phoenix.PubSub

  @max_points_home_score 1
  @max_points_away_score 1
  @max_points_result 2
  @max_points_first_scorer 3
  @max_points_motm 3

  @impl true
  def mount(_params, _session, socket) do
    next_match = get_next_match()
    leaderboard = get_leaderboard()
    current_user = socket.assigns[:current_user]
    user_history = if current_user, do: get_user_history(current_user.id), else: []

    socket =
      socket
      |> assign(:page_title, "Predicciones")
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

    unless user do
      {:noreply, put_flash(socket, :error, "Debés iniciar sesión para hacer predicciones.")}
    else
      with {:ok, home} <- parse_score(home_score),
           {:ok, away} <- parse_score(away_score) do

        prediction = %{
          user_id: user.id,
          match_id: match.id,
          home_score: home,
          away_score: away_score,
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
             |> put_flash(:info, "¡Predicción guardada!")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
      else
        :error -> {:noreply, put_flash(socket, :error, "Los goles deben ser números válidos.")}
      end
    end
  end

  @impl true
  def handle_info({:match_started, _}, socket) do
    {:noreply, socket |> assign(:next_match, nil) |> put_flash(:info, "El partido ya comenzó. No se aceptan más predicciones.")}
  end

  def handle_info({:scores_updated, _}, socket) do
    {:noreply, socket |> assign(:leaderboard, get_leaderboard())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp parse_score(str) do
    case Integer.parse(str) do
      {n, _} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp get_next_match do
    import Ecto.Query

    now = DateTime.utc_now()

    query =
      from(t in Colloq.Forum.Topic,
        where: t.match_date > ^now,
        where: t.match_mode in ["prematch", "live"],
        order_by: [asc: t.match_date],
        limit: 1
      )

    case Repo.all(query) do
      [] -> nil
      [topic | _] ->
        %{
          id: topic.id,
          title: topic.title,
          match_date: topic.match_date,
          home_team: Map.get(topic.match_data || %{}, "home_team", "Local"),
          away_team: Map.get(topic.match_data || %{}, "away_team", "Visitante")
        }
    end
  end

  defp save_prediction(prediction) do
    import Ecto.Query

    # Check if user already predicted this match
    existing =
      Colloq.Predictions.Prediction
      |> where([p], p.user_id == ^prediction.user_id and p.match_id == ^prediction.match_id)
      |> Repo.one()

    schema = if existing, do: existing, else: struct!(Colloq.Predictions.Prediction)

    changeset =
      schema
      |> Ecto.Changeset.cast(prediction, [:user_id, :match_id, :home_score, :away_score, :first_scorer, :motm])
      |> Ecto.Changeset.validate_required([:home_score, :away_score])

    case Repo.insert_or_update(changeset) do
      {:ok, pred} -> {:ok, pred}
      {:error, _} -> {:error, "Error al guardar la predicción."}
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
        match_title: get_match_title(p.match_id),
        home_score: p.home_score,
        away_score: p.away_score,
        points: p.points || 0,
        inserted_at: p.inserted_at
      }
    end)
  end

  defp get_match_title(match_id) do
    case Colloq.Forum.get_topic!(match_id) do
      nil -> "Partido ##{match_id}"
      topic -> topic.title
    end
  rescue
    _ -> "Partido ##{match_id}"
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
          username: if(user, do: user.username, else: "Usuario ##{entry.user_id}"),
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
