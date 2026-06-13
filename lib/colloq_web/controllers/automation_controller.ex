defmodule ColloqWeb.AutomationController do
  use ColloqWeb, :controller

  @moduledoc """
  Automation trigger via API.
  
  POST /api/v1/automations/:id/trigger — externally trigger an automation rule
  Used by webhook integrations and external services.
  """

  def trigger(conn, %{"id" => _id}) do
    json(conn, %{status: "ok"})
  end
end