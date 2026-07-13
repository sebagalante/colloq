defmodule Colloq.PushSubscriptions do
  @moduledoc """
  Web push subscription context (PWA).

  Manages users' Push API subscriptions,
  grouped by team and by user.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.PushSubscriptions.PushSubscription

  @doc """
  Subscribes a user to push notifications.

  Receives user_id and subscription_data with keys: endpoint, p256dh, auth.
  If team_ids is not specified, defaults to [174] (Racing Club).
  """
  def subscribe(user_id, subscription_data) do
    team_ids = Map.get(subscription_data, "team_ids", [174])

    %PushSubscription{}
    |> PushSubscription.changeset(%{
      user_id: user_id,
      endpoint: subscription_data["endpoint"],
      p256dh: subscription_data["p256dh"],
      auth: subscription_data["auth"],
      team_ids: team_ids,
      preferences: Map.get(subscription_data, "preferences", %{})
    })
    |> Repo.insert(
      on_conflict: :replace_all,
      conflict_target: :endpoint
    )
  end

  @doc """
  Unsubscribes a user from a specific endpoint.
  """
  def unsubscribe(user_id, endpoint) do
    sub = Repo.get_by(PushSubscription, user_id: user_id, endpoint: endpoint)

    if sub do
      Repo.delete(sub)
    else
      {:error, :no_encontrado}
    end
  end

  @doc """
  Lists push subscriptions of users who follow a team.

  Useful for sending mass notifications when there is a goal,
  card, or end of match.
  """
  def for_team(team_id) do
    PushSubscription
    |> where([s], fragment("? = ANY(?)", ^team_id, s.team_ids))
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Lists all subscriptions of a user.
  """
  def for_user(user_id) do
    PushSubscription
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end
end
