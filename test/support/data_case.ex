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
      import Colloq.Factory
    end
  end

  @doc """
  Changeset errors as a map of field => messages, with interpolation applied:

      assert "should be at least 5 character(s)" in errors_on(changeset).title
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Colloq.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Colloq.Repo, {:shared, self()})
    end

    :ok
  end
end