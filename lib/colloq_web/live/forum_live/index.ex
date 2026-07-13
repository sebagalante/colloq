defmodule ColloqWeb.ForumLive.Index do
  @moduledoc """
  LiveView for the forum index / landing page.

  Displays a paginated list of topics that can be filtered by category.
  Also provides the "new topic" modal (requires authentication) and
  refreshes in real-time when new topics are created via PubSub.

  Routes:
  - `/` — all topics
  - `/c/:slug` — topics filtered by category
  - `/new` — opens the new-topic modal (live_action: :new_topic)
  """
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Tags
  alias Colloq.Accounts
  alias Phoenix.LiveView.JS

  @per_page 12

  @impl true
  def mount(_params, session, socket) do
    current_user = load_user(session)
    categories = Forum.list_categories()
    blocked_ids = if current_user, do: Accounts.hidden_user_ids(current_user.id), else: MapSet.new()
    muted_ids = if current_user, do: Colloq.Subscriptions.muted_topic_ids(current_user.id), else: MapSet.new()

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:categories, categories)
      |> assign(:selected_category_slug, nil)
      |> assign(:show_modal, false)
      |> assign(:popular_tags, Tags.list_tags() |> Enum.take(20))
      |> assign(:form_tags, "")
      |> assign(:blocked_user_ids, blocked_ids)
      |> assign(:muted_topic_ids, muted_ids)
      |> assign_new(:page_title, fn -> gettext("Forum") end)

    if connected?(socket) do
      ColloqWeb.Endpoint.subscribe("forum:topic_list")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params)
    order = parse_order(params)
    category_id = category_id_from_params(params, socket.assigns.categories)

    topics = Forum.list_topics(page: page, per_page: @per_page, category_id: category_id, order: order, blocked_ids: socket.assigns.blocked_user_ids, muted_topic_ids: socket.assigns.muted_topic_ids)

    # Preload tags for topics
    topic_ids = Enum.map(topics.entries, & &1.id)
    topic_tags = Tags.preload_topic_tags(topic_ids)

    socket =
      socket
      |> assign(:topics, topics.entries)
      |> assign(:topic_tags, topic_tags)
      |> assign(:page, page)
      |> assign(:order, order)
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

  def handle_event("create-topic", %{"title" => title} = params, socket) do
    user = socket.assigns.current_user
    body = params["body"] || ""

    category_id =
      case Integer.parse(to_string(params["category_id"])) do
        {id, _} -> id
        :error -> nil
      end

    # Parse tags from comma-separated string
    tag_names =
      case params["tags"] do
        nil -> []
        tags_str ->
          tags_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    cond do
      is_nil(user) ->
        {:noreply, push_navigate(socket, to: ~p"/login")}

      is_nil(category_id) ->
        {:noreply, put_flash(socket, :error, gettext("Choose a category."))}

      String.trim(title) == "" ->
        {:noreply, put_flash(socket, :error, gettext("The title is required."))}

      true ->
        case Forum.create_topic(user, %{
               "title" => title,
               "category_id" => category_id,
               "body" => body,
               "tags" => tag_names
             }) do
          {:ok, topic} ->
            {:noreply,
             socket
             |> clear_form()
             |> push_navigate(to: ~p"/t/#{topic.id}/#{topic.slug}")}

          {:error, :silenced} ->
            {:noreply, put_flash(socket, :error, gettext("You are silenced and cannot post right now."))}

          {:error, :suspended} ->
            {:noreply, put_flash(socket, :error, gettext("Your account is suspended and cannot post."))}

          {:error, :banned} ->
            {:noreply, put_flash(socket, :error, gettext("Your account is banned."))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not create the topic. Check the fields."))}
        end
    end
  end

  def handle_event("filter-category", %{"slug" => slug}, socket) do
    query = order_query(socket.assigns[:order])

    path =
      if slug == "" do
        ~p"/?#{query}"
      else
        ~p"/c/#{slug}?#{query}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("set-order", %{"order" => order}, socket) do
    slug = socket.assigns.selected_category_slug
    query = order_query(String.to_existing_atom(order))

    path =
      if slug do
        ~p"/c/#{slug}?#{query}"
      else
        ~p"/?#{query}"
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

  def handle_event("add-tag", %{"tag" => tag}, socket) do
    current = socket.assigns.form_tags || ""
    new_tags =
      if current == "" do
        tag
      else
        current <> ", " <> tag
      end

    {:noreply, assign(socket, :form_tags, new_tags)}
  end

  @impl true
  def handle_info(%{event: "topic_created", payload: _payload}, socket) do
    page = socket.assigns.page
    category_id = category_id_from_slug(socket.assigns.selected_category_slug, socket.assigns.categories)

    topics = Forum.list_topics(page: page, per_page: @per_page, category_id: category_id, order: socket.assigns[:order] || :latest, blocked_ids: socket.assigns.blocked_user_ids, muted_topic_ids: socket.assigns.muted_topic_ids)
    topic_ids = Enum.map(topics.entries, & &1.id)
    topic_tags = Tags.preload_topic_tags(topic_ids)

    {:noreply,
     socket
     |> assign(:topics, topics.entries)
     |> assign(:topic_tags, topic_tags)
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

  defp parse_order(%{"order" => "top"}), do: :top
  defp parse_order(_), do: :latest

  # Build the query params for a given order (omit for the default :latest).
  defp order_query(:top), do: [order: "top"]
  defp order_query(_), do: []

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
    |> assign(:form_tags, "")
  end
end
