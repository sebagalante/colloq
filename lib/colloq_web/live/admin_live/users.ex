defmodule ColloqWeb.AdminLive.Users do
  @moduledoc """
  Admin user management LiveView.

  Allows admins to search users, view their moderation status,
  and take actions: warn, suspend (temporary), ban (permanent),
  and reinstate (lift suspension/ban).
  """
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Moderation
  alias Colloq.Permissions

  @page_size 25

  @impl true
  def mount(params, _session, socket) do
    search = params["query"] || ""

    socket =
      socket
      |> assign(:page_title, gettext("Users"))
      |> assign(:users, list_users(1, search))
      |> assign(:search, search)
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:show_moderation_modal, false)
      |> assign(:moderation_user, nil)
      |> assign(:moderation_action, nil)
      |> assign(:moderation_reason, "")
      |> assign(:moderation_duration, "1_day")

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    users = list_users(1, query)

    {:noreply,
     socket
     |> assign(:users, users)
     |> assign(:search, query)
     |> assign(:page, 1)}
  end

  def handle_event("change-page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    users = list_users(page, socket.assigns.search)

    {:noreply,
     socket
     |> assign(:users, users)
     |> assign(:page, page)}
  end

  # Open moderation modal
  def handle_event("moderate", %{"user_id" => user_id, "action" => action}, socket) do
    user = Accounts.get_user!(String.to_integer(user_id))

    {:noreply,
     socket
     |> assign(:show_moderation_modal, true)
     |> assign(:moderation_user, user)
     |> assign(:moderation_action, action)
     |> assign(:moderation_reason, "")
     |> assign(:moderation_duration, "1_day")}
  end

  # Assign or clear a staff role (super_admin only).
  def handle_event("assign-role", %{"user_id" => user_id, "role" => role}, socket) do
    user = Accounts.get_user!(String.to_integer(user_id))

    case Accounts.assign_role(socket.assigns.current_user, user, role) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:users, list_users(socket.assigns.page, socket.assigns.search))
         |> put_flash(:info, gettext("Role updated: %{role}.", role: Permissions.role_name(updated.role)))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You don't have permission for this action."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Action failed."))}
    end
  end

  def handle_event("close-moderation", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_moderation_modal, false)
     |> assign(:moderation_user, nil)}
  end

  def handle_event("confirm-moderation", params, socket) do
    reason = params["reason"] || nil
    duration = params["duration"] || "1_day"
    user = socket.assigns.moderation_user
    action = socket.assigns.moderation_action
    actor = socket.assigns.current_user

    result =
      case action do
        "warn" ->
          Moderation.warn_user(actor, user)

        "silence" ->
          Moderation.silence_user(actor, user, duration, reason)

        "suspend" ->
          Moderation.suspend_user(actor, user, duration, reason)

        "ban" ->
          Moderation.ban_user(actor, user, reason)

        "unsilence" ->
          Moderation.unsilence_user(actor, user)

        "reinstate" ->
          Moderation.reinstate_user(actor, user)

        _ ->
          {:error, :unknown_action}
      end

    case result do
      {:ok, _updated_user} ->
        users = list_users(socket.assigns.page, socket.assigns.search)

        message =
          case action do
            "warn" -> gettext("Warning issued.")
            "silence" -> gettext("User silenced.")
            "suspend" -> gettext("User suspended.")
            "ban" -> gettext("User banned.")
            "unsilence" -> gettext("Silence lifted.")
            "reinstate" -> gettext("User reinstated.")
          end

        {:noreply,
         socket
         |> assign(:show_moderation_modal, false)
         |> assign(:moderation_user, nil)
         |> assign(:users, users)
         |> put_flash(:info, message)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> assign(:show_moderation_modal, false)
         |> put_flash(:error, gettext("You don't have permission for this action."))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:show_moderation_modal, false)
         |> put_flash(:error, gettext("Action failed."))}
    end
  end

  defp list_users(page, search) do
    import Ecto.Query

    query =
      if search != "" do
        term = "%#{search}%"

        from(u in Accounts.User,
          where: ilike(u.username, ^term) or ilike(u.email, ^term) or ilike(u.display_name, ^term),
          order_by: [desc: u.inserted_at]
        )
      else
        from(u in Accounts.User, order_by: [desc: u.inserted_at])
      end

    total = Colloq.Repo.aggregate(query, :count)
    total_pages = max(ceil(total / @page_size), 1)

    users =
      query
      |> limit(^@page_size)
      |> offset(^((page - 1) * @page_size))
      |> Colloq.Repo.all()

    %{entries: users, total_pages: total_pages}
  end

  def user_status(user) do
    cond do
      user.banned -> :banned
      Colloq.Accounts.User.suspended?(user) -> :suspended
      Colloq.Accounts.User.silenced?(user) -> :silenced
      user.warnings_count > 0 -> :warned
      true -> :active
    end
  end

  def status_color(:banned), do: "red"
  def status_color(:suspended), do: "amber"
  def status_color(:silenced), do: "amber"
  def status_color(:warned), do: "yellow"
  def status_color(:active), do: "green"

  def status_label(:banned), do: gettext("Banned")
  def status_label(:suspended), do: gettext("Suspended")
  def status_label(:silenced), do: gettext("Silenced")
  def status_label(:warned), do: gettext("Warned")
  def status_label(:active), do: gettext("Active")
end
