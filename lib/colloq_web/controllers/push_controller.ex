defmodule ColloqWeb.PushController do
  use ColloqWeb, :controller

  @moduledoc """
  Web Push subscription management (PWA).
  
  POST /api/v1/push/subscribe — save browser push subscription
  DELETE /api/v1/push/subscribe — remove subscription
  """

  def subscribe(conn, _params) do
    # TODO: Store push subscription (endpoint, p256dh, auth keys) in push_subscriptions table
    json(conn, %{status: "ok"})
  end

  def unsubscribe(conn, _params) do
    # TODO: Remove push subscription for current user
    json(conn, %{status: "ok"})
  end
end