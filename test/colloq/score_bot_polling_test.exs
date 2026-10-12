defmodule Colloq.ScoreBotPollingTest do
  use Colloq.DataCase, async: true

  import Ecto.Query

  alias Colloq.Workers.ScoreBotWorker

  # `/resultabot` sent twice used to start two loops for one match, doubling
  # every request to Sofascore.
  test "start_polling twice keeps a single loop per fixture" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, first} = ScoreBotWorker.start_polling("16998635", 1)
      {:ok, second} = ScoreBotWorker.start_polling("16998635", 1)

      assert second.conflict?
      assert second.id == first.id

      assert Repo.aggregate(from(j in Oban.Job, where: j.queue == "scorebot"), :count) == 1
    end)
  end

  test "different fixtures each get their own loop" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _} = ScoreBotWorker.start_polling("1", 1)
      {:ok, other} = ScoreBotWorker.start_polling("2", 2)

      refute other.conflict?
    end)
  end
end
