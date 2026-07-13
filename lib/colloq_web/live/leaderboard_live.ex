defmodule ColloqWeb.LeaderboardLive do
  @moduledoc "Top contributors leaderboard."
  use ColloqWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Leaderboard"))
     |> assign(:users, Colloq.Accounts.leaderboard())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-6 flex items-center gap-2">
        <.icon name="award" class="w-6 h-6 text-accent" /><%= gettext("Leaderboard") %>
      </h1>

      <div class="space-y-2">
        <.link
          :for={{u, i} <- Enum.with_index(@users, 1)}
          navigate={~p"/u/#{u.username}"}
          class="flex items-center gap-3 p-3 rounded-xl border border-border bg-surface hover:border-border-hover transition-colors"
        >
          <span class={[
            "flex-shrink-0 w-7 text-center text-sm font-bold tabular-nums",
            i == 1 && "text-amber-400" || i == 2 && "text-slate-300" || i == 3 && "text-amber-700" || "text-muted"
          ]}>
            <%= i %>
          </span>
          <div class="relative flex-shrink-0">
            <img :if={u.avatar_url} src={u.avatar_url} alt="" class="w-10 h-10 rounded-full object-cover" />
            <div
              :if={!u.avatar_url}
              class="w-10 h-10 rounded-full bg-accent flex items-center justify-center text-sm font-bold text-white"
            >
              <%= String.slice(u.display_name || u.username, 0..0) |> String.upcase() %>
            </div>
          </div>
          <div class="min-w-0 flex-1">
            <div class="text-sm font-semibold text-heading truncate"><%= u.display_name || u.username %></div>
            <div class="text-xs text-muted">TL<%= u.trust_level %></div>
          </div>
          <div class="text-right flex-shrink-0">
            <div class="text-base font-bold text-accent tabular-nums"><%= u.posts_count %></div>
            <div class="text-xs text-muted"><%= gettext("posts") %></div>
          </div>
        </.link>
      </div>

      <p :if={@users == []} class="text-center text-muted py-12"><%= gettext("No contributors yet.") %></p>
    </div>
    """
  end
end
