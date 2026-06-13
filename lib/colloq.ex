defmodule Colloq.Application do
  @moduledoc """
  OTP Application supervisor for Colloq.
  
  Supervision tree:
  - Database pool (Colloq.Repo)
  - PubSub (Phoenix.PubSub.PG2)
  - Cachex (forum_cache)
  - Phoenix Endpoint (HTTP/WebSocket)
  - Oban (background job processing)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Colloq.Repo,
      {Phoenix.PubSub, name: Colloq.PubSub},
      {Cachex, name: :forum_cache},
      ColloqWeb.Endpoint,
      {Oban, Application.fetch_env!(:colloq, Oban)}
    ]

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
