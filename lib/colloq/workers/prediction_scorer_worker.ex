defmodule Colloq.Workers.PredictionScorerWorker do
  @moduledoc """
  Post-match prediction scoring worker.

  Enqueued when a match reaches full-time, and again by the nightly sweep for
  anything the full-time hook missed. Loads the unscored predictions for the
  fixture, compares them against the actual result, assigns points, and posts a
  summary in the match thread.

  The worker **fetches the result itself** from `fixture_id`. It used to require
  `home_score`/`away_score` in its args while the only caller
  (`ScoreBotWorker`) passed neither, so every job died on a `FunctionClauseError`
  and no prediction was ever scored. Owning the fetch means there is one code
  path, and callers only need the fixture id.

  A match that isn't finished yet snoozes rather than failing — polling can
  declare FT slightly before the provider's fixture record catches up.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Colloq.Forum
  alias Colloq.Predictions
  alias Colloq.Predictions.Results
  alias Colloq.Accounts

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fixture_id" => fixture_id} = args}) do
    topic_id = args["topic_id"]

    case Results.fetch_result(fixture_id) do
      {:ok, result} ->
        score_and_announce(fixture_id, result, topic_id)

      {:error, :not_finished} ->
        Logger.info("[PredictionScorer] Fixture #{fixture_id} aún no finalizó — reintentando")
        {:snooze, 300}

      {:error, reason} ->
        Logger.error(
          "[PredictionScorer] No se pudo obtener el resultado de #{fixture_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp score_and_announce(fixture_id, result, topic_id) do
    %{home_score: home_score, away_score: away_score} = result

    Logger.info(
      "[PredictionScorer] Puntuando predicciones para fixture #{fixture_id} " <>
        "(#{home_score}-#{away_score})"
    )

    {:ok, count} = Predictions.score_predictions_for_fixture(fixture_id, result)

    # Nothing newly scored means the fixture was already handled — stay quiet
    # rather than posting a duplicate summary in the thread.
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

  defp build_results_body(fixture_id, home_score, away_score, top_users, _leaderboard) do
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
