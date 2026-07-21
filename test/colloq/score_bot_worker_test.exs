defmodule Colloq.ScoreBotWorkerTest do
  use ExUnit.Case, async: true

  alias Colloq.Workers.ScoreBotWorker

  # API-Football returns the fixture's FULL event list on every poll, so the
  # worker has to tell "already posted" from "new". event_key/1 is that
  # identity: stable across polls of the same event, distinct between events.
  defp goal(opts \\ []) do
    %{
      type: Keyword.get(opts, :type, "Goal"),
      player: Keyword.get(opts, :player, "Adrián Martínez"),
      assist: Keyword.get(opts, :assist, nil),
      minute: Keyword.get(opts, :minute, 23),
      detail: Keyword.get(opts, :detail, "Normal Goal"),
      team: Keyword.get(opts, :team, "Racing Club")
    }
  end

  describe "event_key/1" do
    test "is stable across repeated polls of the same event" do
      assert ScoreBotWorker.event_key(goal()) == ScoreBotWorker.event_key(goal())
    end

    test "an assist arriving late does not change the identity" do
      # The API can fill in the assist on a later poll. If that changed the key,
      # the goal would post twice.
      assert ScoreBotWorker.event_key(goal(assist: nil)) ==
               ScoreBotWorker.event_key(goal(assist: "Maravilla"))
    end

    test "distinguishes two goals by the same player at different minutes" do
      refute ScoreBotWorker.event_key(goal(minute: 23)) ==
               ScoreBotWorker.event_key(goal(minute: 67))
    end

    test "distinguishes a goal from a card at the same minute" do
      refute ScoreBotWorker.event_key(goal(type: "Goal")) ==
               ScoreBotWorker.event_key(goal(type: "Card", detail: "Yellow Card"))
    end

    test "distinguishes the same minute for different players" do
      refute ScoreBotWorker.event_key(goal(player: "Solari")) ==
               ScoreBotWorker.event_key(goal(player: "Zuculini"))
    end

    test "distinguishes a penalty from a normal goal" do
      refute ScoreBotWorker.event_key(goal(detail: "Normal Goal")) ==
               ScoreBotWorker.event_key(goal(detail: "Penalty"))
    end

    test "handles a nil player without crashing" do
      assert is_binary(ScoreBotWorker.event_key(goal(player: nil)))
    end
  end

  describe "dedup filtering" do
    test "only events not already posted survive the filter" do
      posted = MapSet.new([ScoreBotWorker.event_key(goal(minute: 23))])

      polled = [goal(minute: 23), goal(minute: 67), goal(minute: 80)]
      new = Enum.reject(polled, &MapSet.member?(posted, ScoreBotWorker.event_key(&1)))

      assert Enum.map(new, & &1.minute) == [67, 80]
    end

    test "a second poll with no new events yields nothing" do
      polled = [goal(minute: 23), goal(minute: 67)]
      posted = MapSet.new(Enum.map(polled, &ScoreBotWorker.event_key/1))

      assert Enum.reject(polled, &MapSet.member?(posted, ScoreBotWorker.event_key(&1))) == []
    end
  end
end
