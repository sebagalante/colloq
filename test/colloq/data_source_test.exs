defmodule Colloq.DataSourceTest do
  use Colloq.DataCase, async: false

  alias Colloq.DataSource

  setup do
    DataSource.clear_cache()
    on_exit(&DataSource.clear_cache/0)
  end

  test "defaults: FotMob for the Prode, Sofascore for standings and match day" do
    assert DataSource.get(:prode) == :fotmob
    assert DataSource.get(:standings) == :sofascore
    assert DataSource.get(:matchday) == :sofascore
  end

  test "a switch applies on the next read and flips the fallback order" do
    {:ok, _} = DataSource.put(:matchday, "fotmob")

    assert DataSource.get(:matchday) == :fotmob
    assert DataSource.order(:matchday) == [:fotmob, :sofascore]
  end

  test "rejects unknown providers" do
    assert {:error, _} = DataSource.put(:prode, "espn")
    assert DataSource.get(:prode) == :fotmob
  end
end
