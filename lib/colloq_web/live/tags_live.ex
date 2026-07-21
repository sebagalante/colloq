defmodule ColloqWeb.TagsLive do
  @moduledoc """
  Public list of every tag.

  The sidebar shows only the top 12 (`Tags.popular_tags/1`), so a tag outside
  that cut was unreachable unless you already knew its URL — with 18 tags in
  use, six of them were invisible. This is the "see all" the sidebar was
  missing, for everyone rather than only staff via the admin CRUD screen.

  Ordered by popularity, since at this size the whole list is scannable and
  what people want first is a sense of what the forum talks about.
  """
  use ColloqWeb, :live_view

  alias Colloq.Tags

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Tags"))
     |> assign(:tags, Tags.list_tags())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-4 py-6">
      <div class="flex items-baseline justify-between gap-3 mb-1">
        <h1 class="text-2xl font-bold text-heading flex items-center gap-2">
          <.icon name="tag" class="w-6 h-6 text-accent" /><%= gettext("Tags") %>
        </h1>
        <span class="text-sm text-muted tabular-nums">
          <%= ngettext("%{count} tag", "%{count} tags", length(@tags), count: length(@tags)) %>
        </span>
      </div>

      <p class="text-sm text-muted mb-5">
        <%= gettext("Every tag on the forum, most used first.") %>
      </p>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <.link
          :for={tag <- @tags}
          navigate={~p"/tag/#{tag.slug}"}
          class="flex items-center gap-3 p-3 rounded-xl border border-border bg-surface hover:border-border-hover transition-colors no-underline"
        >
          <span
            class="flex-shrink-0 w-2.5 h-2.5 rounded-full"
            style={"background-color: #{tag.color}"}
            aria-hidden="true"
          >
          </span>

          <span class="min-w-0 flex-1">
            <span class="block text-sm font-semibold text-heading truncate"><%= tag.name %></span>
            <span :if={tag.description && tag.description != ""} class="block text-xs text-muted truncate">
              <%= tag.description %>
            </span>
          </span>

          <span class="flex-shrink-0 rounded-full bg-surface-alt border border-border px-2 py-0.5 text-xs font-medium tabular-nums text-muted">
            <%= tag.topic_count %>
          </span>
        </.link>
      </div>

      <p :if={@tags == []} class="text-sm text-muted text-center py-10">
        <%= gettext("No tags yet.") %>
      </p>
    </div>
    """
  end
end
