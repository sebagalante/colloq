defmodule ColloqWeb.ForumLive.Index do
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Accounts
  alias Phoenix.LiveView.JS

  @per_page 12

  @impl true
  def mount(_params, session, socket) do
    current_user = load_user(session)
    categories = Forum.list_categories()

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:categories, categories)
      |> assign(:selected_category_slug, nil)
      |> assign(:show_modal, false)
      |> assign_new(:page_title, fn -> "Foro" end)

    if connected?(socket) do
      ColloqWeb.Endpoint.subscribe("forum:topic_list")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params)
    category_id = category_id_from_params(params, socket.assigns.categories)

    topics = Forum.list_topics(page: page, per_page: @per_page, category_id: category_id)

    socket =
      socket
      |> assign(:topics, topics.entries)
      |> assign(:page, page)
      |> assign(:total_pages, topics.total_pages)
      |> assign(:selected_category_slug, params["slug"])

    case socket.assigns.live_action do
      :new_topic ->
        if socket.assigns.current_user do
          {:noreply, assign(socket, :show_modal, true)}
        else
          {:noreply, push_redirect(socket, to: "/login")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open-modal", _params, socket) do
    if socket.assigns.current_user do
      {:noreply, assign(socket, :show_modal, true)}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  def handle_event("close-modal", _params, socket) do
    {:noreply, socket |> assign(:show_modal, false) |> clear_form()}
  end

  def handle_event("create-topic", %{"title" => title, "category_id" => cat_id, "body" => body}, socket) do
    user = socket.assigns.current_user

    case Forum.create_topic(user, %{
      "title" => title,
      "category_id" => String.to_integer(cat_id),
      "body" => body
    }) do
      {:ok, topic} ->
        path = ~p"/t/#{topic.id}/#{topic.slug}"

        {:noreply,
         socket
         |> clear_form()
         |> push_navigate(to: path)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "No se pudo crear el tema. Verificá los campos.")}
    end
  end

  def handle_event("filter-category", %{"slug" => slug}, socket) do
    path =
      if slug == "" do
        ~p"/"
      else
        ~p"/c/#{slug}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("change-page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    slug = socket.assigns.selected_category_slug

    path =
      if slug do
        ~p"/c/#{slug}?page=#{page}"
      else
        ~p"/?page=#{page}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_info(%{event: "topic_created", payload: _payload}, socket) do
    page = socket.assigns.page
    category_id = category_id_from_slug(socket.assigns.selected_category_slug, socket.assigns.categories)

    topics = Forum.list_topics(page: page, per_page: @per_page, category_id: category_id)

    {:noreply,
     socket
     |> assign(:topics, topics.entries)
     |> assign(:total_pages, topics.total_pages)}
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  defp parse_page(params) do
    case Map.get(params, "page") do
      nil -> 1
      str -> String.to_integer(str)
    end
  end

  defp category_id_from_params(params, categories) do
    case Map.get(params, "slug") do
      nil -> nil
      slug -> category_id_from_slug(slug, categories)
    end
  end

  defp category_id_from_slug(slug, categories) do
    Enum.find_value(categories, fn cat -> cat.slug == slug && cat.id end)
  end

  def category_name(categories, slug) do
    Enum.find_value(categories, fn cat -> cat.slug == slug && cat.name end)
  end

  def format_age(datetime) do
    es_locale(datetime)
  end

  defp clear_form(socket) do
    socket
    |> assign(:form_title, "")
    |> assign(:form_category_id, "")
    |> assign(:form_body, "")
  end
end
