defmodule Colloq.PushSubscriptions do
  @moduledoc """
  Contexto de suscripciones a notificaciones push web (PWA).

  Administra las suscripciones Push API de los usuarios,
  agrupadas por equipo y por usuario.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.PushSubscriptions.PushSubscription

  @doc """
  Suscribe a un usuario a notificaciones push.

  Recibe user_id y subscription_data con claves: endpoint, p256dh, auth.
  Si team_ids no se especifica, por defecto es [174] (Racing Club).
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
  Cancela la suscripción de un usuario para un endpoint específico.
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
  Lista las suscripciones push de usuarios que siguen a un equipo.

  Útil para enviar notificaciones masivas cuando hay gol,
  tarjeta o final de partido.
  """
  def for_team(team_id) do
    PushSubscription
    |> where([s], fragment("? = ANY(?)", ^team_id, s.team_ids))
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Lista todas las suscripciones de un usuario.
  """
  def for_user(user_id) do
    PushSubscription
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end
end
