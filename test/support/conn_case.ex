defmodule ColloqWeb.ConnCase do
  @moduledoc """
  Conveniences for testing with connections via Phoenix.ConnTest.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.ConnTest, endpoint: ColloqWeb.Endpoint
      alias Colloq.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import ColloqWeb.ConnCase

      setup tags do
        %{conn: Phoenix.ConnTest.build_conn()}
      end
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Colloq.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Colloq.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end