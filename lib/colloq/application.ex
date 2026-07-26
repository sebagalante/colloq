defmodule Colloq.Application do
  @moduledoc """
  OTP Application supervisor for Colloq.

  Supervision tree:
  - Database pool (Colloq.Repo)
  - PubSub (Phoenix.PubSub.PG2)
  - Cachex (forum_cache, auth_cache)
  - Phoenix Endpoint (HTTP/WebSocket)
  - Oban (background job processing)
  - Telemetry
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Colloq.Repo,
      {Phoenix.PubSub, name: Colloq.PubSub},
      ColloqWeb.Presence,
      Supervisor.child_spec({Cachex, name: :forum_cache}, id: :forum_cache),
      Supervisor.child_spec({Cachex, name: :auth_cache}, id: :auth_cache),
      ColloqWeb.Telemetry,
      ColloqWeb.Endpoint,
      {Oban, Application.fetch_env!(:colloq, Oban)},
      # Both nil when the matching GeoLite2 database isn't configured — see
      # Colloq.GeoIP. Either can be present without the other.
      Colloq.GeoIP.child_spec_or_nil(),
      Colloq.GeoIP.asn_child_spec_or_nil()
    ]
    |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Colloq.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ColloqWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
