defmodule ColloqWeb.AdminLive.Badges do
  use ColloqWeb, :live_view

  alias Colloq.Badges
  alias Colloq.Badges.Badge
  alias Colloq.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Badges"))
      |> assign(:badges, Badges.list_badges())
      |> assign(:show_modal, false)
      |> assign(:editing, nil)
      |> assign(:show_grant_modal, false)
      |> assign(:grant_badge_id, nil)
      |> assign(:grant_username, "")
      |> assign_form(nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, nil)
         |> assign_form(nil)}

      :edit ->
        id = String.to_integer(params["id"])
        badge = Badges.get_badge!(id)

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, badge)
         |> assign_form(badge)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"badge" => attrs}, socket) do
    case socket.assigns.editing do
      nil ->
        case Badges.create_badge(attrs) do
          {:ok, _badge} ->
            {:noreply,
             socket
             |> assign(:badges, Badges.list_badges())
             |> assign(:show_modal, false)
             |> put_flash(:info, gettext("Badge created."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      editing ->
        case Badges.update_badge(editing, attrs) do
          {:ok, _badge} ->
            {:noreply,
             socket
             |> assign(:badges, Badges.list_badges())
             |> assign(:show_modal, false)
             |> assign(:editing, nil)
             |> put_flash(:info, gettext("Badge updated."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    badge = Badges.get_badge!(String.to_integer(id))

    case Badges.delete_badge(badge) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:badges, Badges.list_badges())
         |> put_flash(:info, gettext("Badge deleted."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete badge."))}
    end
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing, nil)
     |> push_patch(to: ~p"/admin/badges")}
  end

  def handle_event("open-new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing, nil)
     |> assign_form(nil)
     |> push_patch(to: ~p"/admin/badges/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    badge = Badges.get_badge!(String.to_integer(id))
    {:noreply, push_patch(socket, to: ~p"/admin/badges/#{badge.id}/edit")}
  end

  # Grant badge modal
  def handle_event("open-grant", %{"badge_id" => badge_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_grant_modal, true)
     |> assign(:grant_badge_id, String.to_integer(badge_id))
     |> assign(:grant_username, "")}
  end

  def handle_event("close-grant", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_grant_modal, false)
     |> assign(:grant_badge_id, nil)}
  end

  def handle_event("grant-badge", %{"username" => username}, socket) do
    badge_id = socket.assigns.grant_badge_id
    admin_user = socket.assigns.current_user

    case Colloq.Accounts.get_user_by_username(username) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("User not found."))}

      user ->
        case Badges.grant_badge(user.id, badge_id, admin_user.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:show_grant_modal, false)
             |> assign(:grant_badge_id, nil)
             |> put_flash(:info, gettext("Badge granted."))}

          {:error, :already_exists} ->
            {:noreply,
             socket
             |> assign(:show_grant_modal, false)
             |> put_flash(:error, gettext("User already has this badge."))}

          {:error, _} ->
            {:noreply,
             socket
             |> assign(:show_grant_modal, false)
             |> put_flash(:error, gettext("Could not grant badge."))}
        end
    end
  end

  def handle_event("revoke-badge", %{"user_id" => user_id, "badge_id" => badge_id}, socket) do
    case Badges.revoke_badge(String.to_integer(user_id), String.to_integer(badge_id)) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, gettext("Badge revoked."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revoke badge."))}
    end
  end

  defp assign_form(socket, nil) do
    assign(socket, :form, to_form(%{
      "name" => "",
      "slug" => "",
      "description" => "",
      "icon" => "🏅",
      "color" => "#3b82f6",
      "position" => "0"
    }, as: :badge))
  end

  defp assign_form(socket, %Badge{} = badge) do
    assign(socket, :form, to_form(%{
      "name" => badge.name || "",
      "slug" => badge.slug || "",
      "description" => badge.description || "",
      "icon" => badge.icon || "🏅",
      "color" => badge.color || "#3b82f6",
      "position" => to_string(badge.position || 0)
    }, as: :badge))
  end
end
