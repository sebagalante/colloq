defmodule ColloqWeb.MembersLive do
  @moduledoc "Public members directory."
  use ColloqWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Members"))
     |> assign(:members, Colloq.Accounts.list_members())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-6 flex items-center gap-2">
        <.icon name="users" class="w-6 h-6 text-accent" /><%= gettext("Members") %>
      </h1>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.link
          :for={u <- @members}
          navigate={~p"/u/#{u.username}"}
          class="flex items-center gap-3 p-3 rounded-xl border border-border bg-surface hover:border-border-hover transition-colors"
        >
          <div class="relative flex-shrink-0">
            <img :if={u.avatar_url} src={u.avatar_url} alt="" class="w-11 h-11 rounded-full object-cover" />
            <div
              :if={!u.avatar_url}
              class="w-11 h-11 rounded-full bg-accent flex items-center justify-center text-sm font-bold text-white"
            >
              <%= String.slice(u.display_name || u.username, 0..0) |> String.upcase() %>
            </div>
            <span
              :if={ColloqWeb.Presence.online?(u.id)}
              class="absolute bottom-0 right-0 w-3 h-3 rounded-full bg-success border-2 border-surface"
              title={gettext("Online")}
            >
            </span>
          </div>
          <div class="min-w-0 flex-1">
            <div class="text-sm font-semibold text-heading truncate"><%= u.display_name || u.username %></div>
            <div class="text-xs text-muted truncate">@<%= u.username %></div>
          </div>
          <div class="text-right flex-shrink-0">
            <div class="text-sm font-semibold text-heading tabular-nums"><%= u.posts_count %></div>
            <div class="text-xs text-muted"><%= gettext("posts") %></div>
          </div>
        </.link>
      </div>

      <p :if={@members == []} class="text-center text-muted py-12"><%= gettext("No members yet.") %></p>
    </div>
    """
  end
end
