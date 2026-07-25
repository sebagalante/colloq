defmodule Colloq.Admin.DashboardDataTest do
  use Colloq.DataCase, async: true

  alias Colloq.Admin.DashboardData
  alias Colloq.Forum.Post
  alias Colloq.Moderation.Flag
  alias Colloq.Reactions.Reaction

  # inserted_at is server-defaulted, so backdating a row means updating it after
  # insert — several of these queries bucket by day.
  defp backdate(schema_struct, days_ago) do
    at = DateTime.add(DateTime.utc_now(), -days_ago * 24 * 3600, :second)

    schema_struct
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end

  describe "kpis/1" do
    test "returns the five tiles in order" do
      ids = DashboardData.kpis(30) |> Enum.map(& &1.id)
      assert ids == ["reg", "new-contrib", "active", "posts", "dau-mau"]
    end

    test "each tile has the shape the tile component renders" do
      for kpi <- DashboardData.kpis(30) do
        assert Map.has_key?(kpi, :label)
        assert Map.has_key?(kpi, :value)
        assert Map.has_key?(kpi, :delta)
        assert Map.has_key?(kpi, :spark)
        assert Map.has_key?(kpi, :sub)
      end
    end

    test "registrations tile counts users in the window and shows the total" do
      insert(:user)
      insert(:user) |> backdate(60)

      reg = DashboardData.kpis(30) |> Enum.find(&(&1.id == "reg"))

      # One registered inside the 30-day window; two total.
      assert reg.value == 1
      assert reg.sub =~ "2"
    end

    test "delta is nil when the previous period had nothing to compare against" do
      insert(:user)
      reg = DashboardData.kpis(30) |> Enum.find(&(&1.id == "reg"))
      assert reg.delta == nil
    end
  end

  describe "time series" do
    setup do
      author = insert(:user)
      topic = insert(:topic, category: insert(:category), user: author)
      %{author: author, topic: topic}
    end

    test "user_growth_series encodes date|count pairs", %{} do
      insert(:user)

      series = DashboardData.user_growth_series(30)
      assert series =~ ~r/^\d{4}-\d{2}-\d{2}\|\d+/
    end

    test "post_activity_series reflects posts in range", %{author: author, topic: topic} do
      insert(:post, topic: topic, user: author)

      assert DashboardData.post_activity_series(30) =~ "|"
    end

    test "a post outside the window is excluded", %{author: author, topic: topic} do
      insert(:post, topic: topic, user: author) |> backdate(60)

      assert DashboardData.post_activity_series(30) == ""
    end

    test "contributors_series counts distinct posters", %{author: author, topic: topic} do
      insert(:post, topic: topic, user: author)
      assert DashboardData.contributors_series(30) =~ "|"
    end
  end

  describe "distribution charts" do
    test "category_activity ranks categories by topic count" do
      hot = insert(:category, name: "Hot")
      cold = insert(:category, name: "Cold")
      user = insert(:user)
      for _ <- 1..3, do: insert(:topic, category: hot, user: user)
      insert(:topic, category: cold, user: user)

      data = DashboardData.category_activity()
      # Busiest category first in the encoded string.
      assert String.starts_with?(data, "Hot|3")
    end

    test "chart labels are stripped of the separators they'd collide with" do
      user = insert(:user)
      insert(:topic, category: insert(:category, name: "A,B|C"), user: user)

      refute DashboardData.category_activity() =~ "A,B|C"
      assert DashboardData.category_activity() =~ "A B C"
    end

    test "flags_by_reason groups by reason" do
      %{user: user, post: post} = flagged_post()
      Repo.insert!(%Flag{reason: "spam", post_id: post.id, user_id: user.id})
      Repo.insert!(%Flag{reason: "spam", post_id: post.id, user_id: user.id})
      Repo.insert!(%Flag{reason: "abuse", post_id: post.id, user_id: user.id})

      data = DashboardData.flags_by_reason()
      assert data =~ "spam|2"
      assert data =~ "abuse|1"
    end

    test "reaction_distribution groups by emoji" do
      %{user: user, post: post} = flagged_post()
      Repo.insert!(%Reaction{emoji: "👍", post_id: post.id, user_id: user.id})
      other = insert(:user)
      Repo.insert!(%Reaction{emoji: "👍", post_id: post.id, user_id: other.id})

      assert DashboardData.reaction_distribution() =~ "👍|2"
    end
  end

  describe "flags" do
    test "recent_flags_count counts only unresolved" do
      %{user: user, post: post} = flagged_post()
      Repo.insert!(%Flag{reason: "spam", post_id: post.id, user_id: user.id, resolved: false})
      Repo.insert!(%Flag{reason: "spam", post_id: post.id, user_id: user.id, resolved: true})

      assert DashboardData.recent_flags_count() == 1
    end

    test "recent_flags flattens the pending queue for the view" do
      %{user: user, post: post, topic: topic} = flagged_post()
      Repo.insert!(%Flag{reason: "spam", post_id: post.id, user_id: user.id})

      assert [flag] = DashboardData.recent_flags()
      assert flag.reason == "spam"
      assert flag.post_id == post.id
      assert flag.topic_id == topic.id
      assert flag.deleted == false
    end
  end

  defp flagged_post do
    user = insert(:user)
    topic = insert(:topic, category: insert(:category), user: user)
    post = insert(:post, topic: topic, user: user)
    %{user: user, topic: topic, post: post}
  end
end
