defmodule Colloq.Workers.TrustPromotionWorker do
  @moduledoc """
  Trust level promotion worker. Checks user activity thresholds nightly.
  Cron: 2:00 AM daily. Will become an automation rule in a future version.

  Thresholds come from the `trust_levels` table (`min_posts` /
  `min_days_registered`) — each row describes what it takes to *reach* that
  level, so promoting into TL2 reads TL2's row. They used to be hardcoded here
  while the table went unread, which let the two drift apart.

  Levels are processed high-to-low so each user advances at most one level per
  run. Low-to-high would cascade — every batch re-queries the DB, so a user
  promoted into TL1 early in the pass would still be sitting at `trust_level: 1`
  when the TL2 batch ran and would jump again, collecting a pile of
  notifications in one night.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  alias Colloq.Accounts
  alias Colloq.Notifications
  alias Colloq.Trust

  @impl Oban.Worker
  def perform(_job) do
    promoted =
      Trust.list_levels()
      # TL0 is the floor — nobody is promoted *into* it.
      |> Enum.reject(&(&1.level == 0))
      |> Enum.sort_by(& &1.level, :desc)
      |> Enum.flat_map(&promote_batch/1)

    {:ok, length(promoted)}
  end

  defp promote_batch(%Trust.TrustLevel{} = level) do
    promote_batch(%{
      from: level.level - 1,
      to: level.level,
      min_posts: level.min_posts,
      min_days: level.min_days_registered,
      name: level.name
    })
  end

  defp promote_batch(%{from: from, to: to, min_posts: posts, min_days: days, name: name}) do
    Accounts.list_eligible_for_promotion(from, posts, days)
    |> Enum.map(fn user ->
      case Accounts.update_trust_level(user, to) do
        {:ok, updated} ->
          notify_promotion(updated, name)
          updated

        {:error, _} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp notify_promotion(user, level_name) do
    Notifications.create_notification(%{
      type: "trust_promotion",
      title: "¡Subiste de nivel!",
      body: "Ahora sos nivel #{level_name} (TL#{user.trust_level}). Desbloqueaste nuevas funciones.",
      user_id: user.id,
      data: %{new_level: user.trust_level, level_name: level_name}
    })
  end
end