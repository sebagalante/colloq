defmodule ColloqWeb.TopicBarsTest do
  use ColloqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Colloq.Factory

  @endpoint ColloqWeb.Endpoint

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  setup do
    user = insert(:user)
    topic = insert(:topic, category: insert(:category), user: user)
    insert(:post, topic: topic, user: user, post_number: 1)
    %{user: user, topic: topic}
  end

  test "renders the stat chips and action pills in both the header and footer bar", ctx do
    conn = Plug.Test.init_test_session(ctx.conn, %{"user_id" => ctx.user.id})
    {:ok, _view, html} = live(conn, "/t/#{ctx.topic.id}")

    # One clock chip per stat group — header + footer.
    assert count(html, ~s(title="#{Gettext.gettext(ColloqWeb.Gettext, "Read time")}")) == 2

    # Action pills appear twice, with distinct ids so JS.toggle and
    # LiveViewTest can each address a single element.
    assert count(html, ~s(phx-click="show-summary")) == 2
    assert html =~ ~s(id="header-summarize")
    assert html =~ ~s(id="footer-summarize")
    assert html =~ ~s(id="header-notif-level-menu")
    assert html =~ ~s(id="footer-notif-level-menu")
  end

  test "the footer Top replies pill re-sorts, exactly like the header one", ctx do
    conn = Plug.Test.init_test_session(ctx.conn, %{"user_id" => ctx.user.id})

    low = insert(:post, topic: ctx.topic, user: ctx.user, post_number: 2, reactions_count: 0)
    high = insert(:post, topic: ctx.topic, user: ctx.user, post_number: 3, reactions_count: 9)

    {:ok, view, html} = live(conn, "/t/#{ctx.topic.id}")
    assert order(html) |> Enum.take(-2) == [low.id, high.id]

    top = view |> element("#footer-sort") |> render_click() |> order()
    assert Enum.take(top, -2) == [high.id, low.id], "footer Top replies did not re-sort"
  end

  defp order(html) do
    Regex.scan(~r/id="post-(\d+)"/, html)
    |> Enum.map(fn [_, id] -> String.to_integer(id) end)
    |> Enum.uniq()
  end

  test "the footer bookmark pill toggles the same state as the header one", ctx do
    conn = Plug.Test.init_test_session(ctx.conn, %{"user_id" => ctx.user.id})
    {:ok, view, _html} = live(conn, "/t/#{ctx.topic.id}")

    html = view |> element("#footer-bookmark") |> render_click()

    # Both copies reflect the new state, so the two bars cannot drift apart.
    assert count(html, ~s(phx-click="toggle-topic-bookmark")) == 2
    assert count(html, Gettext.gettext(ColloqWeb.Gettext, "Bookmarked")) >= 2
  end
end
