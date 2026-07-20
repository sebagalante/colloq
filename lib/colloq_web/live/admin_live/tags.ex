defmodule ColloqWeb.AdminLive.Tags do
  @moduledoc """
  Admin management of tags: create, edit (name/slug/description/color) and
  delete. Deleting a tag removes it from all topics.
  """
  use ColloqWeb, :live_view

  alias Colloq.Tags
  alias Colloq.Forum.Tag

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Tags"))
      |> assign(:tags, Tags.list_tags())
      |> assign(:show_modal, false)
      |> assign(:editing, nil)
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
        tag = Tags.get_tag!(String.to_integer(params["id"]))

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, tag)
         |> assign_form(tag)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"tag" => attrs}, socket) do
    case socket.assigns.editing do
      nil ->
        case Tags.create_tag(attrs) do
          {:ok, _tag} ->
            {:noreply,
             socket
             |> assign(:tags, Tags.list_tags())
             |> assign(:show_modal, false)
             |> push_patch(to: ~p"/admin/tags")
             |> put_flash(:info, gettext("Tag created."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      editing ->
        case Tags.update_tag(editing, attrs) do
          {:ok, _tag} ->
            {:noreply,
             socket
             |> assign(:tags, Tags.list_tags())
             |> assign(:show_modal, false)
             |> assign(:editing, nil)
             |> push_patch(to: ~p"/admin/tags")
             |> put_flash(:info, gettext("Tag updated."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    tag = Tags.get_tag!(String.to_integer(id))
    {:ok, _} = Tags.delete_tag(tag)

    {:noreply,
     socket
     |> assign(:tags, Tags.list_tags())
     |> put_flash(:info, gettext("Tag deleted."))}
  end

  def handle_event("open-new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing, nil)
     |> assign_form(nil)
     |> push_patch(to: ~p"/admin/tags/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    tag = Tags.get_tag!(String.to_integer(id))
    {:noreply, push_patch(socket, to: ~p"/admin/tags/#{tag.id}/edit")}
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing, nil)
     |> push_patch(to: ~p"/admin/tags")}
  end

  defp assign_form(socket, nil) do
    assign(
      socket,
      :form,
      to_form(%{"name" => "", "slug" => "", "description" => "", "color" => "#6b7280"}, as: :tag)
    )
  end

  defp assign_form(socket, %Tag{} = tag) do
    assign(
      socket,
      :form,
      to_form(
        %{
          "name" => tag.name || "",
          "slug" => tag.slug || "",
          "description" => tag.description || "",
          "color" => tag.color || "#6b7280"
        },
        as: :tag
      )
    )
  end
end
