defmodule ColloqWeb.AdminLive.Categories do
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Forum.Category
  alias Colloq.Repo

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Categories"))
      |> assign(:categories, Forum.list_categories())
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
        id = String.to_integer(params["id"])
        category = Forum.get_category!(id)

        {:noreply,
         socket
         |> assign(:show_modal, true)
         |> assign(:editing, category)
         |> assign_form(category)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"category" => attrs}, socket) do
    case socket.assigns.editing do
      nil ->
        case Forum.create_category(attrs) do
          {:ok, category} ->
            {:noreply,
             socket
             |> assign(:categories, Forum.list_categories())
             |> assign(:show_modal, false)
             |> put_flash(:info, gettext("Category created."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      editing ->
        case Forum.update_category(editing, attrs) do
          {:ok, _category} ->
            {:noreply,
             socket
             |> assign(:categories, Forum.list_categories())
             |> assign(:show_modal, false)
             |> assign(:editing, nil)
             |> put_flash(:info, gettext("Category updated."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    category = Forum.get_category!(String.to_integer(id))

    case Forum.delete_category(category) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:categories, Forum.list_categories())
         |> put_flash(:info, gettext("Category deleted."))}

      {:error, :has_topics} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot delete category with topics. Move or delete them first."))}
    end
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing, nil)
     |> push_patch(to: ~p"/admin/categories")}
  end

  def handle_event("open-new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing, nil)
     |> assign_form(nil)
     |> push_patch(to: ~p"/admin/categories/new")}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    category = Forum.get_category!(String.to_integer(id))
    {:noreply, push_patch(socket, to: ~p"/admin/categories/#{category.id}/edit")}
  end

  defp assign_form(socket, nil) do
    assign(socket, :form, to_form(%{
      "name" => "",
      "slug" => "",
      "description" => "",
      "color" => "#3b82f6",
      "icon" => "",
      "position" => "0",
      "read_restricted" => "false",
      "write_restricted" => "false",
      "required_trust_level" => "0",
      "parent_id" => ""
    }, as: :category))
  end

  defp assign_form(socket, %Category{} = category) do
    assign(socket, :form, to_form(%{
      "name" => category.name || "",
      "slug" => category.slug || "",
      "description" => category.description || "",
      "color" => category.color || "#3b82f6",
      "icon" => category.icon || "",
      "position" => to_string(category.position || 0),
      "read_restricted" => to_string(category.read_restricted),
      "write_restricted" => to_string(category.write_restricted),
      "required_trust_level" => to_string(category.required_trust_level || 0),
      "parent_id" => to_string(category.parent_id || "")
    }, as: :category))
  end

  # Candidate parents: top-level categories only (one nesting level), never the
  # category being edited.
  def parent_options(categories, editing) do
    editing_id = editing && editing.id

    Enum.filter(categories, fn c ->
      is_nil(c.parent_id) && c.id != editing_id
    end)
  end
end
