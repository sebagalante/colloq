defmodule ColloqWeb.AdminLive.Dashboard do
  use ColloqWeb, :live_view

  alias Colloq.Repo
  alias Colloq.Accounts
  alias Colloq.Forum
  alias Colloq.Moderation
  alias Colloq.Reactions
  alias Phoenix.PubSub

  @impl true
  def mount(_params, _session, socket) do
    stats = load_stats()

    socket =
      socket
      |> assign(:page_title, "Panel de Control")
      |> assign(:stats, stats)
      |> assign(:user_growth_data, user_growth_chart_data())
      |> assign(:post_activity_data, post_activity_chart_data())
      |> assign(:reaction_distribution, reaction_distribution_data())
      |> assign(:recent_flags, recent_flags())

    if connected?(socket) do
      PubSub.subscribe(Colloq.PubSub, "admin:dashboard")
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:dashboard_refresh, payload}, socket) do
    stats =
      case payload do
        %{kind: "flag"} ->
          Map.put(socket.assigns.stats, :flags_count, recent_flags_count())
          |> Map.put(:recent_flags, recent_flags())

        %{kind: "user"} ->
          Map.put(socket.assigns.stats, :total_users, total_users())

        %{kind: "topic"} ->
          Map.put(socket.assigns.stats, :total_topics, total_topics())

        %{kind: "post"} ->
          Map.put(socket.assigns.stats, :total_posts, total_posts())

        _ ->
          load_stats()
      end

    socket =
      socket
      |> assign(:stats, stats)
      |> assign(:recent_flags, recent_flags())

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  # Dismiss a report without hiding the post.
  def handle_event("dismiss-flag", %{"id" => id}, socket) do
    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "dismissed")

    {:noreply,
     socket
     |> refresh_flags()
     |> put_flash(:info, gettext("Report dismissed."))}
  end

  # Hide the reported post and resolve the report.
  def handle_event("hide-flagged-post", %{"id" => id, "post_id" => post_id}, socket) do
    case Repo.get(Colloq.Forum.Post, String.to_integer(post_id)) do
      nil -> :ok
      post -> Moderation.hide_post(post)
    end

    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "post_hidden")

    {:noreply,
     socket
     |> refresh_flags()
     |> put_flash(:info, gettext("Post hidden and report resolved."))}
  end

  defp refresh_flags(socket) do
    socket
    |> assign(:recent_flags, recent_flags())
    |> assign(:stats, Map.put(socket.assigns.stats, :flags_count, recent_flags_count()))
  end

  defp load_stats do
    %{
      total_users: total_users(),
      total_topics: total_topics(),
      total_posts: total_posts(),
      online_users: online_users_count(),
      flags_count: recent_flags_count()
    }
  end

  defp total_users, do: Repo.aggregate(Colloq.Accounts.User, :count, :id)
  defp total_topics, do: Repo.aggregate(Colloq.Forum.Topic, :count, :id)

  defp total_posts, do: Repo.aggregate(Colloq.Forum.Post, :count, :id)

  defp online_users_count do
    import Ecto.Query

    Repo.aggregate(
      from(u in Colloq.Accounts.User, where: u.updated_at > ago(15, "minute")),
      :count,
      :id
    )
  end

  defp recent_flags_count do
    import Ecto.Query

    Repo.aggregate(
      from(f in Colloq.Moderation.Flag, where: f.resolved == false),
      :count,
      :id
    )
  end

  defp recent_flags do
    Moderation.list_pending_flags()
    |> Enum.take(10)
    |> Enum.map(fn flag ->
      post = if Ecto.assoc_loaded?(flag.post), do: flag.post, else: nil

      %{
        id: flag.id,
        reason: flag.reason,
        inserted_at: flag.inserted_at,
        post_id: flag.post_id,
        topic_id: post && post.topic_id,
        deleted: post && post.deleted_at != nil,
        excerpt: post && flag_excerpt(post.body),
        user: if(Ecto.assoc_loaded?(flag.user) && flag.user, do: flag.user.username, else: nil)
      }
    end)
  end

  defp flag_excerpt(nil), do: ""

  defp flag_excerpt(body) do
    body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.slice(0, 160)
  end

  defp user_growth_chart_data do
    import Ecto.Query

    rows =
      from(u in Colloq.Accounts.User,
        group_by: fragment("date_trunc('day', ?)", u.inserted_at),
        order_by: fragment("date_trunc('day', ?)", u.inserted_at),
        select: %{
          date: fragment("date_trunc('day', ?)", u.inserted_at),
          count: count(u.id)
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        "#{Date.to_string(row.date)}|#{row.count}"
      end)
      |> Enum.join(",")

    rows
  end

  defp post_activity_chart_data do
    import Ecto.Query

    rows =
      from(p in Colloq.Forum.Post,
        group_by: fragment("date_trunc('day', ?)", p.inserted_at),
        order_by: fragment("date_trunc('day', ?)", p.inserted_at),
        where: p.inserted_at > ago(30, "day"),
        select: %{
          date: fragment("date_trunc('day', ?)", p.inserted_at),
          count: count(p.id)
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        "#{Date.to_string(row.date)}|#{row.count}"
      end)
      |> Enum.join(",")

    rows
  end

  defp reaction_distribution_data do
    import Ecto.Query

    rows =
      from(r in Colloq.Reactions.Reaction,
        group_by: r.emoji,
        order_by: [desc: count(r.id)],
        limit: 10,
        select: %{emoji: r.emoji, count: count(r.id)}
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        "#{row.emoji}|#{row.count}"
      end)
      |> Enum.join(",")

    rows
  end
end
