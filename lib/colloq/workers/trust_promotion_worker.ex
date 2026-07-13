defmodule Colloq.Workers.TrustPromotionWorker do
  @moduledoc """
  Trust level promotion worker. Checks user activity thresholds nightly.
  Cron: 2:00 AM daily. Will become an automation rule in a future version.

  Thresholds:
  - TL0 → TL1: 10 posts, 1 day registered (Básico)
  - TL1 → TL2: 50 posts, 7 days registered (Miembro)
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  alias Colloq.Accounts
  alias Colloq.Notifications
  import Ecto.Query

  @promotions [
    %{from: 0, to: 1, min_posts: 10, min_days: 1, name: "Básico"},
    %{from: 1, to: 2, min_posts: 50, min_days: 7, name: "Miembro"}
  ]

  @impl Oban.Worker
  def perform(_job) do
    promoted = Enum.flat_map(@promotions, &promote_batch/1)

    {:ok, length(promoted)}
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