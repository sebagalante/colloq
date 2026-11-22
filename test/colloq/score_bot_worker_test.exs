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

  # When the match-day source flips mid-match, FotMob reports what Sofascore
  # already did under different keys and slightly different minutes.
  describe "already_posted?/3 across providers" do
    defp posted_goal,
      do: %{"key" => "123", "type" => "goal", "team" => "Racing Club", "minute" => 29, "home_score" => 1, "away_score" => 0}

    test "a goal is recognised by the score it produced" do
      fotmob = %{id: "fotmob:goal:30:0:1", type: "goal", team: "Racing Club", minute: 30, home_score: 1, away_score: 0}
      assert ScoreBotWorker.already_posted?(fotmob, :fotmob, [posted_goal()])
    end

    test "a later goal is new" do
      fotmob = %{id: "fotmob:goal:70:0:1", type: "goal", team: "Racing Club", minute: 70, home_score: 2, away_score: 0}
      refute ScoreBotWorker.already_posted?(fotmob, :fotmob, [posted_goal()])
    end

    test "a card a minute apart from the same team is the same card" do
      posted = %{"key" => "9", "type" => "card", "team" => "River Plate", "minute" => 40, "source" => "sofascore"}
      card = %{id: "fotmob:card:41:0:5:yellow", type: "card", team: "River Plate", minute: 41}
      assert ScoreBotWorker.already_posted?(card, :fotmob, [posted])
    end

    # Within one provider the key alone decides: two subs in the same minute
    # (a double change) are two events.
    test "same-provider events only match by key" do
      posted = %{"key" => "fotmob:substitution:72:0:1:2", "type" => "sub", "team" => "Racing Club", "minute" => 72, "source" => "fotmob"}
      other = %{id: "fotmob:substitution:72:0:3:4", type: "sub", team: "Racing Club", minute: 72}
      refute ScoreBotWorker.already_posted?(other, :fotmob, [posted])
    end
  end
end
