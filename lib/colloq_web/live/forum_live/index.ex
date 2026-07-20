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

  @per_page 20

  @impl true
  def mount(_params, session, socket) do
    current_user = load_user(session)
    categories = Forum.list_categories(current_user)
    blocked_ids = if current_user, do: Accounts.hidden_user_ids(current_user.id), else: MapSet.new()
    muted_ids = if current_user, do: Colloq.Subscriptions.muted_topic_ids(current_user.id), else: MapSet.new()
    hidden_cats = Forum.hidden_category_ids(current_user)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:categories, categories)
      |> assign(:selected_category_slug, nil)
      |> assign(:tag_slug, nil)
      |> assign(:show_modal, false)
      |> assign(:popular_tags, Tags.list_tags() |> Enum.take(20))
      |> assign(:form_tags, "")
      |> assign(:blocked_user_ids, blocked_ids)
      |> assign(:muted_topic_ids, muted_ids)
      # Ids of the hottest topics (most activity in the last 48h) so the list can
      # tag them with a 🔥 badge. Computed once here.
      |> assign(:hidden_category_ids, hidden_cats)
      |> assign(
        :hot_topic_ids,
        Forum.hot_topic_ids(
          blocked_ids: blocked_ids,
          muted_topic_ids: muted_ids,
          hidden_category_ids: hidden_cats
        )
      )
      # Infinite-scroll + "new topics" banner state.
      |> assign(:page, 1)
      |> assign(:has_more, false)
      |> assign(:loads, 0)
      |> assign(:topics_empty?, false)
      |> assign(:new_count, 0)
      |> assign(:pending_ids, MapSet.new())
      |> stream(:topics, [])
      |> assign_new(:page_title, fn -> gettext("Forum") end)

    if connected?(socket) do
      ColloqWeb.Endpoint.subscribe("forum:topic_list")
    end

    {:ok, socket}
  end

  # After this many auto-loads on scroll, stop auto-loading and show a button —
  # "infinite, but controlled": it never scrolls forever.
  @auto_batches 3

  @impl true
  def handle_params(params, _uri, socket) do
    order = parse_order(params)

    # The same LiveView serves /, /c/:slug and /tag/:slug — the live_action
    # decides whether the slug is a category or a tag.
    {category_slug, tag_slug} =
      case socket.assigns.live_action do
        :tag -> {nil, params["slug"]}
        :category -> {params["slug"], nil}
        _ -> {nil, nil}
      end

    socket =
      socket
      |> assign(:order, order)
      |> assign(:selected_category_slug, category_slug)
      |> assign(:tag_slug, tag_slug)
      # A filter/sort change is a fresh list: reset scroll + banner state.
      |> assign(:loads, 0)
      |> reset_banner()
      |> load_page(1, reset: true)

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

  def handle_event("set-order", %{"order" => order}, socket) do
    query = order_query(String.to_existing_atom(order))

    path =
      cond do
        socket.assigns.tag_slug -> ~p"/tag/#{socket.assigns.tag_slug}?#{query}"
        socket.assigns.selected_category_slug -> ~p"/c/#{socket.assigns.selected_category_slug}?#{query}"
        true -> ~p"/?#{query}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  # Append the next page. The scroll hook fires this automatically for the first
  # @auto_batches loads; after that the template shows a "Load more" button that
  # fires the same event.
  def handle_event("load-more", _params, socket) do
    if socket.assigns.has_more do
      socket = assign(socket, :loads, socket.assigns.loads + 1)
      {:noreply, load_page(socket, socket.assigns.page + 1, reset: false)}
    else
      {:noreply, socket}
    end
  end

  # Banner clicked — reload the freshest first page and clear the pending count.
  def handle_event("show-new-topics", _params, socket) do
    {:noreply,
     socket
     |> assign(:loads, 0)
     |> reset_banner()
     |> load_page(1, reset: true)}
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

  # New or bumped topic elsewhere: don't disrupt the reader's scroll — buffer it
  # into the banner and let them choose to refresh. Distinct topic ids are
  # counted once (a topic bumped twice still reads as one update).
  @impl true
  def handle_info(%{event: event, payload: payload}, socket)
      when event in ["topic_created", "topic_bumped"] do
    viewing = category_id_from_slug(socket.assigns.selected_category_slug, socket.assigns.categories)

    if relevant_to_view?(payload, viewing) do
      pending = MapSet.put(socket.assigns.pending_ids, payload.topic_id)
      {:noreply, socket |> assign(:pending_ids, pending) |> assign(:new_count, MapSet.size(pending))}
    else
      {:noreply, socket}
    end
  end

  # When viewing "All", everything is relevant; in a category, only that category.
  defp relevant_to_view?(_payload, nil), do: true
  defp relevant_to_view?(%{category_id: cid}, viewing), do: cid == viewing
  defp relevant_to_view?(_payload, _viewing), do: true

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  # Load a page of topics into the stream (reset the list, or append the next
  # page), and refresh the has-more flag. `decorate/1` attaches tags,
  # participants and an excerpt so each stream row is self-contained.
  defp load_page(socket, page, opts) do
    reset? = Keyword.get(opts, :reset, false)
    a = socket.assigns
    category_id = category_id_from_slug(a.selected_category_slug, a.categories)

    result =
      Forum.list_topics(
        page: page,
        per_page: @per_page,
        category_id: category_id,
        tag_slug: a.tag_slug,
        order: a.order || :latest,
        blocked_ids: a.blocked_user_ids,
        muted_topic_ids: a.muted_topic_ids,
        hidden_category_ids: a.hidden_category_ids
      )

    socket
    |> stream(:topics, decorate(result.entries), reset: reset?)
    |> assign(:page, page)
    |> assign(:has_more, page < result.total_pages)
    |> then(fn s -> if reset?, do: assign(s, :topics_empty?, result.entries == []), else: s end)
  end

  defp decorate(topics) do
    ids = Enum.map(topics, & &1.id)
    tags = Tags.preload_topic_tags(ids)
    participants = Forum.topic_participants(ids)

    Enum.map(topics, fn t ->
      %{
        id: t.id,
        topic: t,
        tags: Map.get(tags, t.id, []),
        participants: Map.get(participants, t.id, []),
        excerpt: excerpt(t)
      }
    end)
  end

  defp excerpt(%{first_post: %{body: body}}) when is_binary(body) do
    case body |> HtmlSanitizeEx.strip_tags() |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      # CSS truncates to one line; this just caps the payload.
      text -> truncate(text, 140)
    end
  end

  defp excerpt(_), do: nil

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp reset_banner(socket) do
    socket |> assign(:new_count, 0) |> assign(:pending_ids, MapSet.new())
  end

  @doc "Auto-load this many batches on scroll before switching to a button."
  def auto_batches, do: @auto_batches

  defp parse_order(%{"order" => "top"}), do: :top
  defp parse_order(%{"order" => "replies"}), do: :replies
  defp parse_order(_), do: :latest

  # Build the query params for a given order (omit for the default :latest).
  # The "Views" column and "Top" tab share :top; "Activity" and "Latest" share
  # the default; "Replies" is its own sort.
  defp order_query(:top), do: [order: "top"]
  defp order_query(:replies), do: [order: "replies"]
  defp order_query(_), do: []

  defp category_id_from_slug(slug, categories) do
    Enum.find_value(categories, fn cat -> cat.slug == slug && cat.id end)
  end

  def category_name(categories, slug) do
    Enum.find_value(categories, fn cat -> cat.slug == slug && cat.name end)
  end

  def format_age(datetime) do
    es_locale(datetime)
  end

  @doc "Stable display color for a tag: its custom color, else one from its name."
  defdelegate tag_color(tag), to: Colloq.Tags, as: :color

  @doc "Abbreviate large counts, Discourse-style: 999, 1.2k, 3.4m."
  def format_count(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}m"

  def format_count(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}k"

  def format_count(n) when is_integer(n), do: Integer.to_string(n)
  def format_count(_), do: "0"

  defp clear_form(socket) do
    socket
    |> assign(:form_title, "")
    |> assign(:form_category_id, "")
    |> assign(:form_body, "")
    |> assign(:form_tags, "")
  end
end
