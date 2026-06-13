defmodule Colloq.DataCase do
  @moduledoc """
  Conveniences for testing contexts with Ecto.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Colloq.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Colloq.DataCase
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