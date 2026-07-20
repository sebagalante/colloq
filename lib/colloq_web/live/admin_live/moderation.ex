defmodule ColloqWeb.AdminLive.Moderation do
  @moduledoc """
  Moderation queue LiveView, reachable by moderators (and above).

  Two tabs:
    - "reports"  — pending flags with hide/dismiss actions
    - "hidden"   — soft-deleted posts with a restore action

  Unlike the admin Dashboard (admin+), this screen is gated only by
  `:resolve_flags`, so plain moderators can actually work the queue.
  """
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Moderation
  alias Colloq.Repo

  @impl true
  def mount(_params, _session, socket) do
    if Colloq.Permissions.can?(socket.assigns.current_user, :resolve_flags) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Moderation"))
       |> assign(:tab, "reports")
       |> load_reports()
       |> load_hidden()
       |> load_deleted_topics()
       |> load_sanctioned()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have permission to moderate."))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket)
      when tab in ~w(reports hidden deleted_topics banned) do
    {:noreply, assign(socket, :tab, tab)}
  end

  # Restore a soft-deleted topic (moderator+).
  def handle_event("restore-topic", %{"id" => id}, socket) do
    if Colloq.Permissions.can?(socket.assigns.current_user, :delete_topics) do
      case Repo.get(Colloq.Forum.Topic, String.to_integer(id)) do
        nil -> :ok
        topic -> Forum.restore_topic(topic)
      end

      {:noreply,
       socket
       |> load_deleted_topics()
       |> put_flash(:info, gettext("Topic restored."))}
    else
      {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}
    end
  end

  # Lift a ban/suspension (reinstate — super_admin only).
  def handle_event("reinstate-user", %{"id" => id}, socket) do
    user = Colloq.Accounts.get_user!(String.to_integer(id))

    case Moderation.reinstate_user(socket.assigns.current_user, user) do
      {:ok, _} ->
        {:noreply, socket |> load_sanctioned() |> put_flash(:info, gettext("User reinstated."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Action failed."))}
    end
  end

  # Lift a silence (moderator+).
  def handle_event("unsilence-user", %{"id" => id}, socket) do
    user = Colloq.Accounts.get_user!(String.to_integer(id))

    case Moderation.unsilence_user(socket.assigns.current_user, user) do
      {:ok, _} ->
        {:noreply, socket |> load_sanctioned() |> put_flash(:info, gettext("Silence lifted."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Action failed."))}
    end
  end

  # Dismiss a report without hiding the post.
  def handle_event("dismiss-flag", %{"id" => id}, socket) do
    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "dismissed")

    {:noreply,
     socket
     |> load_reports()
     |> put_flash(:info, gettext("Report dismissed."))}
  end

  # Hide the reported post and resolve the report.
  def handle_event("hide-flagged-post", %{"id" => id, "post_id" => post_id}, socket) do
    case Repo.get(Colloq.Forum.Post, String.to_integer(post_id)) do
      nil -> :ok
      post -> Moderation.hide_post(post, socket.assigns.current_user)
    end

    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "post_hidden")

    {:noreply,
     socket
     |> load_reports()
     |> load_hidden()
     |> put_flash(:info, gettext("Post hidden and report resolved."))}
  end

  # Restore a hidden post.
  def handle_event("restore-post", %{"id" => id}, socket) do
    case Repo.get(Colloq.Forum.Post, String.to_integer(id)) do
      nil -> :ok
      post -> Moderation.restore_post(post)
    end

    {:noreply,
     socket
     |> load_hidden()
     |> put_flash(:info, gettext("Post restored."))}
  end

  defp load_reports(socket) do
    reports =
      Moderation.list_pending_flags()
      |> Enum.map(fn flag ->
        post = if Ecto.assoc_loaded?(flag.post), do: flag.post, else: nil
        post = post && Repo.preload(post, [:user, :topic])

        %{
          id: flag.id,
          reason: flag.reason,
          inserted_at: flag.inserted_at,
          post_id: flag.post_id,
          topic_id: post && post.topic_id,
          topic_slug: post && post.topic && post.topic.slug,
          author: post && post.user && post.user.username,
          hidden: post && post.hidden,
          excerpt: post && excerpt(post.body),
          reporter: if(Ecto.assoc_loaded?(flag.user) && flag.user, do: flag.user.username, else: nil)
        }
      end)

    assign(socket, :reports, reports)
  end

  defp load_hidden(socket) do
    hidden =
      Moderation.list_hidden_posts()
      |> Enum.map(fn post ->
        %{
          id: post.id,
          deleted_at: post.deleted_at,
          topic_id: post.topic_id,
          topic_slug: post.topic && post.topic.slug,
          topic_title: post.topic && post.topic.title,
          author: post.user && post.user.username,
          hidden_by:
            cond do
              !Ecto.assoc_loaded?(post.deleted_by) -> nil
              post.deleted_by -> post.deleted_by.display_name || post.deleted_by.username
              true -> gettext("automatic")
            end,
          excerpt: excerpt(post.body)
        }
      end)

    assign(socket, :hidden, hidden)
  end

  defp load_deleted_topics(socket) do
    topics =
      Forum.list_deleted_topics()
      |> Enum.map(fn t ->
        %{
          id: t.id,
          title: t.title,
          deleted_at: t.deleted_at,
          category: t.category && t.category.name,
          author: t.user && t.user.username,
          deleted_by: t.deleted_by && (t.deleted_by.display_name || t.deleted_by.username)
        }
      end)

    assign(socket, :deleted_topics, topics)
  end

  defp load_sanctioned(socket) do
    now = DateTime.utc_now()

    users =
      Moderation.list_sanctioned_users()
      |> Enum.map(fn u ->
        status =
          cond do
            u.banned -> :banned
            u.suspended_until && DateTime.compare(u.suspended_until, now) == :gt -> :suspended
            u.silenced_until && DateTime.compare(u.silenced_until, now) == :gt -> :silenced
            true -> :active
          end

        %{
          id: u.id,
          username: u.username,
          display_name: u.display_name,
          avatar_url: u.avatar_url,
          status: status,
          reason: u.ban_reason || u.suspension_reason || u.silence_reason,
          until: u.suspended_until || u.silenced_until,
          at: u.banned_at || u.suspended_at || u.silenced_at
        }
      end)

    assign(socket, :sanctioned, users)
  end

  defp excerpt(nil), do: ""

  defp excerpt(body) do
    body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.slice(0, 200)
  end

  def status_label(:banned), do: gettext("Banned")
  def status_label(:suspended), do: gettext("Suspended")
  def status_label(:silenced), do: gettext("Silenced")
  def status_label(_), do: gettext("Active")

  def status_color(:banned), do: "red"
  def status_color(:suspended), do: "amber"
  def status_color(:silenced), do: "amber"
  def status_color(_), do: "green"

  def reason_label("spam"), do: gettext("Spam")
  def reason_label("inappropriate"), do: gettext("Inappropriate")
  def reason_label("off_topic"), do: gettext("Off topic")
  def reason_label("harassment"), do: gettext("Harassment")
  def reason_label(_), do: gettext("Other")
end
