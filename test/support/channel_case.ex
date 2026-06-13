defmodule ColloqWeb.ChannelCase do
  @moduledoc """
  Conveniences for testing Phoenix channels.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.ChannelTest, endpoint: ColloqWeb.Endpoint
      alias Colloq.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Colloq.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Colloq.Repo, {:shared, self()})
    end

    :ok
  end
end