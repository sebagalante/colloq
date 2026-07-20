defmodule Colloq.Workers.PredictionDigestWorker do
  @moduledoc """
  Nightly prediction sweep and daily digest.

  Cron: 3:00 AM daily (after `TrustPromotionWorker` at 02:00, so the digest
  reflects any promotions from the same night).

  Two jobs in one pass:

    1. **Sweep** — every fixture with unscored predictions gets a
       `PredictionScorerWorker` job. The full-time hook in `ScoreBotWorker` is
       the fast path, but it only fires while the poller is running: a match
       the bot never polled, an API blip, or a fixture that finished after the
       process restarted would otherwise leave predictions unscored forever.
       Scoring is idempotent, so re-queueing a fixture already handled is a
       no-op.

    2. **Digest** — posts the current leaderboard to the configured topic, once
       per day. Skipped when no predictions were scored that day, so a quiet
       week doesn't fill a thread with identical tables.

  The digest topic comes from the `prediction_digest_topic_id` site setting.
  Unset means sweep-only — no digest post.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Colloq.{Accounts, Forum, Predictions, Repo, SiteSettings}
  alias Colloq.Predictions.Prediction
  alias Colloq.Workers.PredictionScorerWorker

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    swept = sweep_unscored()
    posted = maybe_post_digest()

    Logger.info("[PredictionDigest] #{swept} fixtures encolados, digest: #{posted}")
    {:ok, %{swept: swept, digest: posted}}
  end

  # --- Sweep -----------------------------------------------------------------

  defp sweep_unscored do
    fixture_ids = Predictions.unscored_fixture_ids()

    Enum.each(fixture_ids, fn fixture_id ->
      %{"fixture_id" => fixture_id, "topic_id" => topic_id_for(fixture_id)}
      |> PredictionScorerWorker.new()
      |> Oban.insert()
    end)

    length(fixture_ids)
  end

  # Match threads carry the fixture id in `match_id`; without one the scorer
  # still awards points, it just has nowhere to post the summary.
  defp topic_id_for(fixture_id) do
    Repo.one(
      from t in Forum.Topic,
        where: t.is_match_thread == true and t.match_id == ^fixture_id,
        select: t.id,
        limit: 1
    )
  end

  # --- Digest ----------------------------------------------------------------

  defp maybe_post_digest do
    with topic_id when is_integer(topic_id) <- digest_topic_id(),
         scored_today when scored_today > 0 <- count_scored_today() do
      post_digest(topic_id, scored_today)
      :posted
    else
      nil -> :no_topic_configured
      0 -> :nothing_scored
      _ -> :skipped
    end
  end

  defp digest_topic_id do
    case SiteSettings.get("prediction_digest_topic_id") do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp count_scored_today do
    since = DateTime.utc_now() |> DateTime.add(-1, :day)

    Repo.one(
      from p in Prediction,
        where: not is_nil(p.scored_at) and p.scored_at >= ^since,
        select: count(p.id)
    )
  end

  defp post_digest(topic_id, scored_today) do
    leaderboard = Predictions.leaderboard(limit: 10)
    topic = Forum.get_topic!(topic_id)
    system_user = find_system_user()

    Forum.create_post(topic, system_user, %{
      "body" => build_digest_body(leaderboard, scored_today),
      "is_system" => true,
      "system_type" => "prediction_digest",
      "event_data" => %{scored_today: scored_today, entries: length(leaderboard)}
    })
  end

  defp build_digest_body(leaderboard, scored_today) do
    rows =
      leaderboard
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {%{user: user, total_points: pts, predictions_count: n}, pos} ->
        name = user_name(user)
        "<tr><td>#{medal(pos)}</td><td>#{name}</td><td>#{pts}</td><td>#{n}</td></tr>"
      end)

    """
    <h2>📊 Tabla de Predicciones</h2>
    <p>#{scored_today} predicciones puntuadas en las últimas 24 horas.</p>
    <table>
      <thead><tr><th>#</th><th>Usuario</th><th>Puntos</th><th>Predicciones</th></tr></thead>
      <tbody>
    #{rows}
      </tbody>
    </table>
    <p><em>Tabla completa en <a href="/predicciones">Predicciones</a></em></p>
    """
  end

  defp medal(1), do: "🥇"
  defp medal(2), do: "🥈"
  defp medal(3), do: "🥉"
  defp medal(pos), do: to_string(pos)

  defp user_name(nil), do: "Usuario"
  defp user_name(user), do: user.display_name || user.username

  defp find_system_user do
    case Accounts.get_user_by_username("scorebot") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end
end
