defmodule ColloqWeb.AdminSpamTest do
  @moduledoc """
  The spam-classifier dashboard.

  Scores used to exist only in the log, so "is it safe to enforce?" meant
  grepping journald. These cover the queries that replace that.
  """
  use ColloqWeb.ConnCase
  import Phoenix.LiveViewTest
  import Colloq.Factory
  import ColloqWeb.Gettext

  alias Colloq.Moderation

  @endpoint ColloqWeb.Endpoint

  setup do
    admin = insert(:user, role: "admin", is_admin: true)
    author = insert(:user, trust_level: 1)
    topic = insert(:topic, category: insert(:category), user: author)

    # post_number is unique per topic, so each helper call needs its own.
    post = fn body ->
      insert(:post,
        topic: topic,
        user: author,
        body: body,
        post_number: System.unique_integer([:positive, :monotonic])
      )
    end

    %{admin: admin, author: author, topic: topic, post: post}
  end

  defp record(post, user, score, opts \\ []) do
    Moderation.record_spam_classification(%{
      post_id: post.id,
      user_id: user.id,
      score: score,
      threshold: Keyword.get(opts, :threshold, 0.9),
      would_flag: score >= Keyword.get(opts, :threshold, 0.9),
      mode: Keyword.get(opts, :mode, "shadow"),
      acted: Keyword.get(opts, :acted, false)
    })
  end

  defp open(conn, admin) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => admin.id})
    live(conn, "/admin/spam")
  end

  describe "stats" do
    test "counts screenings, over-threshold and acted separately", ctx do
      %{author: author, post: post} = ctx

      record(post.("<p>hola</p>"), author, 0.05)
      record(post.("<p>spam</p>"), author, 0.95)
      record(post.("<p>spam 2</p>"), author, 0.99, mode: "enforce", acted: true)

      stats = Moderation.spam_stats(7)

      assert stats.total == 3
      assert stats.would_flag == 2, "0.95 and 0.99 are both over 0.9"
      assert stats.acted == 1, "only the enforce-mode one was acted on"
    end

    test "an empty window reports zeroes rather than nils" do
      stats = Moderation.spam_stats(7)

      assert stats.total == 0
      assert stats.would_flag == 0
      assert stats.acted == 0
    end
  end

  describe "histogram" do
    test "always returns ten buckets, counting into the right one", ctx do
      %{author: author, post: post} = ctx

      record(post.("a"), author, 0.05)
      record(post.("b"), author, 0.15)
      record(post.("c"), author, 0.95)

      buckets = Moderation.spam_score_histogram(7)

      assert length(buckets) == 10
      assert Enum.at(buckets, 0).count == 1
      assert Enum.at(buckets, 1).count == 1
      assert Enum.at(buckets, 9).count == 1
      assert Enum.at(buckets, 5).count == 0
    end

    test "a score of exactly 1.0 lands in the last bucket, not an 11th", ctx do
      %{author: author, post: post} = ctx
      record(post.("a"), author, 1.0)

      buckets = Moderation.spam_score_histogram(7)

      assert length(buckets) == 10
      assert Enum.at(buckets, 9).count == 1
    end
  end

  describe "threshold simulation" do
    test "counts what a given cutoff would have flagged", ctx do
      %{author: author, post: post} = ctx

      for s <- [0.10, 0.60, 0.80, 0.92, 0.99], do: record(post.("x"), author, s)

      assert Moderation.spam_would_flag_at(0.9, 7) == 2
      assert Moderation.spam_would_flag_at(0.75, 7) == 3
      assert Moderation.spam_would_flag_at(0.05, 7) == 5
    end
  end

  describe "the page" do
    test "renders status, distribution and recent rows", ctx do
      %{conn: conn, admin: admin, author: author, post: post} = ctx

      record(post.("<p>sospechoso</p>"), author, 0.97)

      {:ok, _view, html} = open(conn, admin)

      assert html =~ gettext("Spam classifier")
      assert html =~ gettext("Score distribution")
      assert html =~ gettext("Recent screenings")
      # The score is rendered as a percentage.
      assert html =~ "97.0"
      # Shadow-mode row: flagged by score but nothing done about it.
      assert html =~ gettext("Would flag")
    end

    test "says the sidecar isn't configured rather than looking healthy", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, _view, html} = open(conn, admin)

      assert html =~ gettext("Not configured")
    end

    test "the threshold slider updates the count", ctx do
      %{conn: conn, admin: admin, author: author, post: post} = ctx

      for s <- [0.55, 0.95], do: record(post.("x"), author, s)

      {:ok, view, _html} = open(conn, admin)

      html = render_change(view, "simulate", %{"threshold" => "0.5"})
      assert html =~ "2"

      html = render_change(view, "simulate", %{"threshold" => "0.99"})
      assert html =~ gettext("of %{total} screened", total: 2)
    end

    test "an empty dashboard doesn't crash on max_by over zero counts", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, _view, html} = open(conn, admin)

      assert html =~ gettext("Nothing screened in this window yet.")
    end
  end

  describe "blocked words" do
    test "a stray comma can no longer match every post", ctx do
      %{post: post} = ctx

      # This is the landmine: "viagra, , casino" used to parse to
      # ["viagra", "", "casino"], and String.contains?(anything, "") is true,
      # so one typo hid the entire forum.
      Colloq.SiteSettings.put("blocked_words", "viagra, , casino", type: "string", group: "forum")

      assert Moderation.blocked_words() == ["viagra", "casino"]
      refute Moderation.blocked_word_hit("hola muchachos, buen partido")
      assert Moderation.blocked_word_hit("comprá VIAGRA barato") == "viagra"

      # And the worker agrees, since it now shares the same parser.
      p = post.("<p>hola muchachos, buen partido</p>")
      assert Colloq.Workers.SpamDetectorWorker.perform(%Oban.Job{args: %{"post_id" => p.id}}) == :ok
    end

    test "add trims, rejects blanks and duplicates" do
      assert {:ok, _} = Moderation.add_blocked_word("  casino  ")
      assert Moderation.blocked_words() == ["casino"]

      assert {:error, :blank} = Moderation.add_blocked_word("   ")
      assert {:error, :duplicate} = Moderation.add_blocked_word("CASINO")
      assert Moderation.blocked_words() == ["casino"]
    end

    test "remove is case-insensitive" do
      {:ok, _} = Moderation.add_blocked_word("Casino")
      {:ok, _} = Moderation.add_blocked_word("viagra")

      Moderation.remove_blocked_word("casino")

      assert Moderation.blocked_words() == ["viagra"]
    end

    test "a word with a comma in it can't corrupt the list" do
      # Stored comma-separated, so an embedded comma would split into two.
      {:ok, _} = Moderation.add_blocked_word("gana dinero, ya")

      assert Moderation.blocked_words() == ["gana dinero", "ya"]
      # Whatever the split, no entry is ever blank.
      refute Enum.any?(Moderation.blocked_words(), &(&1 == ""))
    end

    test "the page manages the list", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = open(conn, admin)

      html = render_submit(view, "add-word", %{"word" => "casino"})
      assert html =~ "casino"
      assert Moderation.blocked_words() == ["casino"]

      html = render_submit(view, "add-word", %{"word" => "casino"})
      assert html =~ gettext("That word is already on the list.")

      html = render_click(view, "remove-word", %{"word" => "casino"})
      assert html =~ gettext("No blocked words. This rule is doing nothing right now.")
      assert Moderation.blocked_words() == []
    end

    test "the tester names the word that matched", ctx do
      %{conn: conn, admin: admin} = ctx
      {:ok, _} = Moderation.add_blocked_word("casino")

      {:ok, view, _html} = open(conn, admin)

      html = render_change(view, "test-words", %{"sample" => "vengan al CASINO online"})
      assert html =~ gettext("Would be blocked by %{word}", word: "casino")

      html = render_change(view, "test-words", %{"sample" => "qué partidazo"})
      assert html =~ gettext("Would pass this rule.")
    end
  end

  describe "polling" do
    test "a refresh tick picks up screenings recorded since mount", ctx do
      %{conn: conn, admin: admin, author: author, post: post} = ctx

      {:ok, view, html} = open(conn, admin)
      assert html =~ gettext("Nothing screened in this window yet.")

      # Happens elsewhere while the page sits open.
      record(post.("<p>spam</p>"), author, 0.97)

      # The interval fires this; sending it directly avoids a 30s test.
      send(view.pid, :refresh)

      html = render(view)
      refute html =~ gettext("Nothing screened in this window yet.")
      assert html =~ "97.0"
    end

    test "a refresh picks up blocked words added elsewhere", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, html} = open(conn, admin)
      assert html =~ gettext("No blocked words. This rule is doing nothing right now.")

      {:ok, _} = Moderation.add_blocked_word("casino")
      send(view.pid, :refresh)

      assert render(view) =~ "casino"
    end
  end

  describe "blocked-word normalisation" do
    setup do
      Colloq.SiteSettings.put("blocked_words", "viagra, casino", type: "string", group: "forum")
      :ok
    end

    test "case, accents and leetspeak don't get past it" do
      for text <- ["VIAGRA barato", "ViAgRa", "víagra", "vi4gra", "VÍAGRA"] do
        assert Moderation.blocked_word_hit(text) == "viagra", "#{text} got through"
      end

      for text <- ["CASINO", "cásino", "c4s1n0", "C4S1N0 online"] do
        assert Moderation.blocked_word_hit(text) == "casino", "#{text} got through"
      end
    end

    test "the word is reported as the admin typed it, not normalised" do
      {:ok, _} = Moderation.add_blocked_word("Jackpot")
      assert Moderation.blocked_word_hit("gané el j4ckp0t") == "Jackpot"
    end

    test "an admin can type the word with accents or digits too" do
      Colloq.SiteSettings.put("blocked_words", "víagra", type: "string", group: "forum")
      assert Moderation.blocked_word_hit("comprá viagra") == "víagra"
    end

    test "ordinary text with numbers is not caught" do
      for text <- ["jugamos 4-0", "el partido a las 15:30", "3 puntos de oro", "temporada 2026"] do
        refute Moderation.blocked_word_hit(text), "#{text} was wrongly blocked"
      end
    end

    test "a word that normalises to nothing can't match everything" do
      # The empty-needle trap again, this time via normalisation rather than a
      # stray comma: a "word" of only combining marks folds to "".
      Colloq.SiteSettings.put("blocked_words", "\u0301, casino", type: "string", group: "forum")

      refute Moderation.blocked_word_hit("hola muchachos")
      assert Moderation.blocked_word_hit("casino") == "casino"
    end

    test "documented gaps stay documented" do
      # Not handled by design — spacing needs whitespace stripping (false
      # positives across word boundaries) and homoglyphs are unbounded.
      refute Moderation.blocked_word_hit("v i a g r a")
      refute Moderation.blocked_word_hit("vıagra")
    end
  end
end
