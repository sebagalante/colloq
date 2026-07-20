defmodule ColloqWeb.SearchLive do
  use ColloqWeb, :live_view

  alias Colloq.Forum

  @min_query 2

  @impl true
  def mount(params, _session, socket) do
    q = params["q"] || ""

    {:ok,
     socket
     |> assign(:page_title, gettext("Search"))
     |> assign(:search_query, q)
     |> run_search(q)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search_query, q) |> run_search(q)}
  end

  defp run_search(socket, q) do
    q = String.trim(q || "")
    hidden_cats = Forum.hidden_category_ids(socket.assigns[:current_user])

    if String.length(q) < @min_query do
      socket
      |> assign(:topics, [])
      |> assign(:posts, [])
      |> assign(:searched, false)
    else
      socket
      # Staff-only categories must not surface through search either.
      |> assign(:topics, Forum.search_topics(q, limit: 20, hidden_category_ids: hidden_cats))
      |> assign(:posts, Forum.search_posts(q, limit: 20, hidden_category_ids: hidden_cats))
      |> assign(:searched, true)
    end
  end

  # Plain-text preview of a post body (which is stored as HTML).
  defp snippet(body) do
    (body || "")
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-4"><%= gettext("Search") %></h1>

      <%!-- Mobile-only box; on desktop the header search bar drives this page. --%>
      <form phx-change="search" phx-submit="search" class="mb-6 sm:hidden">
        <div class="flex items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 focus-within:border-accent focus-within:ring-2 focus-within:ring-accent">
          <.icon name="search" class="w-4 h-4 text-muted flex-shrink-0" />
          <input
            type="text"
            name="q"
            value={@search_query}
            autofocus
            autocomplete="off"
            phx-debounce="250"
            placeholder={gettext("Search topics and posts…")}
            class="flex-1 bg-transparent text-heading text-sm focus:outline-none placeholder:text-muted"
          />
        </div>
      </form>

      <p :if={!@searched} class="text-sm text-muted">
        <%= gettext("Type at least 2 characters to search.") %>
      </p>

      <div :if={@searched}>
        <%!-- Topics --%>
        <div class="mb-8">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-muted mb-2">
            <%= gettext("Topics") %> (<%= length(@topics) %>)
          </h2>
          <p :if={@topics == []} class="text-sm text-muted"><%= gettext("No matching topics.") %></p>
          <ul class="space-y-1">
            <li :for={topic <- @topics}>
              <.link
                navigate={~p"/t/#{topic.id}/#{topic.slug}"}
                class="block rounded-lg px-3 py-2 hover:bg-surface-alt transition-colors"
              >
                <div class="flex items-center gap-2">
                  <.badge color={topic.category.color || "blue"}><%= topic.category.name %></.badge>
                  <span class="text-sm font-medium text-heading truncate"><%= topic.title %></span>
                </div>
                <div class="text-xs text-muted mt-0.5">
                  @<%= topic.user.username %> · <%= topic.posts_count %> <%= gettext("posts") %>
                </div>
              </.link>
            </li>
          </ul>
        </div>

        <%!-- Posts --%>
        <div>
          <h2 class="text-xs font-semibold uppercase tracking-wide text-muted mb-2">
            <%= gettext("Posts") %> (<%= length(@posts) %>)
          </h2>
          <p :if={@posts == []} class="text-sm text-muted"><%= gettext("No matching posts.") %></p>
          <ul class="space-y-1">
            <li :for={post <- @posts}>
              <%!-- Anchor to the matched post, not just its topic: a search hit
                    that drops you at the top of a 200-reply thread hasn't
                    answered the search. ~p can't take a fragment straight after
                    an interpolation, hence the concatenation. --%>
              <.link
                navigate={"#{~p"/t/#{post.topic.id}/#{post.topic.slug}"}#post-#{post.id}"}
                class="block rounded-lg px-3 py-2 hover:bg-surface-alt transition-colors"
              >
                <div class="text-sm text-body line-clamp-2"><%= snippet(post.body) %></div>
                <div class="text-xs text-muted mt-0.5">
                  @<%= post.user.username %> <%= gettext("in") %>
                  <span class="text-body"><%= post.topic.title %></span>
                </div>
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
