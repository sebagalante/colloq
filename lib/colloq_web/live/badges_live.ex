defmodule ColloqWeb.BadgesLive do
  @moduledoc "Public list of available badges."
  use ColloqWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Badges"))
     |> assign(:badges, Colloq.Badges.list_badges())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-6 flex items-center gap-2">
        <.icon name="star" class="w-6 h-6 text-accent" /><%= gettext("Badges") %>
      </h1>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div
          :for={badge <- @badges}
          class="flex items-center gap-3 p-4 rounded-xl border border-border bg-surface"
        >
          <div
            class="flex-shrink-0 w-12 h-12 rounded-lg flex items-center justify-center text-2xl"
            style={"background-color: #{badge.color}20"}
          >
            <%= badge.icon %>
          </div>
          <div class="min-w-0">
            <div class="text-sm font-semibold text-heading truncate"><%= badge.name %></div>
            <div :if={badge.description} class="text-xs text-muted mt-0.5"><%= badge.description %></div>
          </div>
        </div>
      </div>

      <p :if={@badges == []} class="text-center text-muted py-12"><%= gettext("No badges yet.") %></p>
    </div>
    """
  end
end
