defmodule Colloq.Workers.PredictionScorerWorker do
  @moduledoc """
  Post-match prediction scoring worker.

  Enqueued when a match reaches full-time (FT).
  Loads all predictions for the fixture_id, compares them
  against the actual result, and assigns points.
  Then posts the results in the match thread.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Predictions
  alias Colloq.Accounts

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "fixture_id" => fixture_id,
    "home_score" => home_score,
    "away_score" => away_score,
    "topic_id" => topic_id
  }}) do
    Logger.info("[PredictionScorer] Puntuando predicciones para fixture #{fixture_id} " <>
                "(#{home_score}-#{away_score})")

    {:ok, count} = Predictions.score_predictions_for_fixture(fixture_id, home_score, away_score)

    if count > 0 && topic_id do
      post_results(topic_id, fixture_id, home_score, away_score)
    end

    Logger.info("[PredictionScorer] #{count} predicciones puntuadas para #{fixture_id}")
    :ok
  end

  defp post_results(topic_id, fixture_id, home_score, away_score) do
    leaderboard = Predictions.leaderboard(limit: 10)
    top_users = Enum.take(leaderboard, 3)

    system_user = find_system_user()
    topic = Forum.get_topic!(topic_id)

    body = build_results_body(fixture_id, home_score, away_score, top_users, leaderboard)

    Forum.create_post(topic, system_user, %{
      "body" => body,
      "is_system" => true,
      "system_type" => "prediction_results",
      "event_data" => %{
        fixture_id: fixture_id,
        home_score: home_score,
        away_score: away_score,
        scored_count: length(leaderboard)
      }
    })
  end

  defp build_results_body(fixture_id, home_score, away_score, top_users, leaderboard) do
    resultado = "#{home_score} - #{away_score}"
    top3 =
      top_users
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%{user: user, total_points: pts}, pos} ->
        user_name = if user, do: user.display_name || user.username, else: "Usuario"
        medalla = case pos do
          1 -> "🥇"
          2 -> "🥈"
          3 -> "🥉"
        end
        "#{medalla} **#{user_name}** — #{pts} pts"
      end)

    """
    <h2>🏁 Resultado Final: #{resultado}</h2>
    <p>Todas las predicciones del partido <code>#{fixture_id}</code> fueron puntuadas.</p>

    <h3>Podio de Predicciones</h3>
    #{top3}

    <p><em>Consultá la tabla completa en <a href="/predicciones">Predicciones</a></em></p>
    """
  end

  defp find_system_user do
    case Accounts.get_user_by_username("scorebot") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end
end
