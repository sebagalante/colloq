defmodule ColloqWeb.NecropostNoticeTest do
  use ColloqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Colloq.Factory

  alias Colloq.Repo
  alias ColloqWeb.ForumLive.Topic, as: TopicLive

  @endpoint ColloqWeb.Endpoint

  defp bumped_days_ago(topic, days) do
    topic
    |> Ecto.Changeset.change(bumped_at: DateTime.add(DateTime.utc_now(), -days, :day))
    |> Repo.update!()
  end

  defp open(conn, user, topic) do
    conn = Plug.Test.init_test_session(conn, %{"user_id" => user.id})
    {:ok, _view, html} = live(conn, "/t/#{topic.id}")
    html
  end

  setup do
    # Locale comes from user.locale || "es" (see UserAuth), so pinning the user
    # to English keeps these assertions readable and independent of how the
    # Spanish copy is worded.
    user = insert(:user, locale: "en")
    topic = insert(:topic, category: insert(:category), user: user)
    insert(:post, topic: topic, user: user, post_number: 1)
    %{user: user, topic: topic}
  end

  describe "necropost_days/1" do
    test "is nil for an active thread" do
      refute TopicLive.necropost_days(%{bumped_at: DateTime.utc_now()})
    end

    test "is nil just under the threshold" do
      refute TopicLive.necropost_days(%{
               bumped_at: DateTime.add(DateTime.utc_now(), -89, :day)
             })
    end

    test "reports the gap once past the threshold" do
      assert TopicLive.necropost_days(%{bumped_at: DateTime.add(DateTime.utc_now(), -120, :day)}) ==
               120
    end

    test "tolerates a topic with no bumped_at" do
      refute TopicLive.necropost_days(%{bumped_at: nil})
    end
  end

  describe "necropost_label/1" do
    # Pure functions run in the test process, which has no request locale.
    setup do
      Gettext.put_locale(ColloqWeb.Gettext, "en")
      :ok
    end

    test "reports coarse units rather than raw days" do
      assert TopicLive.necropost_label(120) == "4 months"
      assert TopicLive.necropost_label(400) == "1 year"
      assert TopicLive.necropost_label(30) == "30 days"
    end
  end

  test "an active topic shows no notice", ctx do
    refute open(ctx.conn, ctx.user, ctx.topic) =~ "The last reply here was"
  end

  test "a long-quiet topic warns, and the gap reaches the markup", ctx do
    topic = bumped_days_ago(ctx.topic, 120)
    html = open(ctx.conn, ctx.user, topic)

    # Also proves the `days` bound in the :if condition is visible in the body.
    assert html =~ "The last reply here was 4 months ago."
  end

  test "the composer stays usable — the notice is advisory, not a lock", ctx do
    topic = bumped_days_ago(ctx.topic, 200)
    html = open(ctx.conn, ctx.user, topic)

    assert html =~ "The last reply here was"
    assert html =~ ~s(id="reply-form")
    assert html =~ "reply-composer"
  end
end
