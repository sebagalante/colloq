defmodule ColloqWeb.LeaderboardLive do
  @moduledoc "Top contributors leaderboard, ranked by engagement score."
  use ColloqWeb, :live_view

  # Scores are recomputed by the "Recompute scores" automation every few
  # minutes; re-pull periodically so an open leaderboard keeps up on its own.
  @refresh_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Leaderboard"))
     |> assign(:users, Colloq.Accounts.leaderboard())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :users, Colloq.Accounts.leaderboard())}
  end

  @impl true
  def render(assigns) do
    # The top three get the podium; everyone else the ranked list. Split here
    # rather than in mount so a refresh can't leave the two out of sync.
    assigns =
      assigns
      |> assign(:podium, Enum.take(assigns.users, 3))
      |> assign(:rest, Enum.drop(assigns.users, 3))

    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-2 flex items-center gap-2">
        <.icon name="award" class="w-6 h-6 text-accent" /><%= gettext("Leaderboard") %>
      </h1>
      <p class="text-sm text-muted mb-6 leading-relaxed">
        <%= gettext(
          "Points are awarded for engaging with the community — visiting, liking, and posting. Your score updates every few minutes. Be helpful, active, and supportive, and climb the ranks!"
        ) %>
      </p>

      <%!-- Podium: 2nd, 1st, 3rd — the winner centred and raised, the way a
            real podium reads. Ordered by rank in the DOM (1st, 2nd, 3rd) and
            re-ordered visually, so screen readers still hear the true order. --%>
      <div :if={@podium != []} class="rounded-2xl border border-border bg-surface-alt px-4 pt-8 pb-6 mb-6">
        <div class="flex items-end justify-center gap-3 sm:gap-6">
          <.podium_place :for={{u, rank} <- Enum.with_index(@podium, 1)} user={u} rank={rank} />
        </div>
      </div>

      <div :if={@rest != []} class="flex items-center justify-between px-3 mb-2">
        <span class="text-xs font-semibold uppercase tracking-wide text-muted"><%= gettext("Rank") %></span>
        <span class="text-xs font-semibold uppercase tracking-wide text-muted"><%= gettext("Points") %></span>
      </div>

      <div class="space-y-2">
        <.link
          :for={{u, i} <- Enum.with_index(@rest, 4)}
          navigate={~p"/u/#{u.username}"}
          class="flex items-center gap-3 p-3 rounded-xl border border-border bg-surface hover:border-border-hover transition-colors"
        >
          <span class="flex-shrink-0 w-7 text-center text-sm font-bold tabular-nums text-muted">
            <%= i %>
          </span>
          <div class="relative flex-shrink-0">
            <img :if={u.avatar_url} src={u.avatar_url} alt="" class="w-10 h-10 rounded-full object-cover" />
            <div
              :if={!u.avatar_url}
              class="w-10 h-10 rounded-full bg-accent flex items-center justify-center text-sm font-bold text-white"
            >
              <%= initial(u) %>
            </div>
          </div>
          <div class="min-w-0 flex-1">
            <div class="text-sm font-semibold text-heading truncate"><%= u.display_name || u.username %></div>
            <div class="text-xs text-muted">
              <span :if={Colloq.Permissions.staff?(@current_user)}>TL<%= u.trust_level %> · </span><%= ngettext("%{count} post", "%{count} posts", u.posts_count) %>
            </div>
          </div>
          <div class="text-right flex-shrink-0">
            <div class="text-base font-bold text-accent tabular-nums"><%= u.score %></div>
          </div>
        </.link>
      </div>

      <p :if={@users == []} class="text-center text-muted py-12"><%= gettext("No contributors yet.") %></p>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :rank, :integer, required: true

  defp podium_place(assigns) do
    ~H"""
    <.link
      navigate={~p"/u/#{@user.username}"}
      class={[
        # Fixed, equal width per place: columns sized to their content made the
        # centre column drift whenever one name was longer than another. It also
        # gives `truncate` below something to truncate against.
        "flex flex-col items-center w-24 sm:w-28 shrink-0 group",
        # Visual order 2-1-3 while the DOM keeps 1-2-3 for screen readers.
        @rank == 1 && "order-2",
        @rank == 2 && "order-1",
        @rank == 3 && "order-3"
      ]}
    >
      <%!-- Crown only for the winner; the medal colours carry the other two. --%>
      <span :if={@rank == 1} class="text-2xl leading-none mb-1" aria-hidden="true">👑</span>

      <div class="relative">
        <img
          :if={@user.avatar_url}
          src={@user.avatar_url}
          alt=""
          class={["rounded-full object-cover ring-4", avatar_size(@rank), ring_class(@rank)]}
        />
        <div
          :if={!@user.avatar_url}
          class={[
            "rounded-full bg-accent flex items-center justify-center font-bold text-white ring-4",
            avatar_size(@rank),
            ring_class(@rank),
            (@rank == 1 && "text-2xl") || "text-xl"
          ]}
        >
          <%= initial(@user) %>
        </div>

        <span class={[
          "absolute -bottom-2 left-1/2 -translate-x-1/2 w-7 h-7 rounded-full",
          "flex items-center justify-center text-xs font-bold tabular-nums",
          "ring-2 ring-surface-alt",
          badge_class(@rank)
        ]}>
          <%= @rank %>
        </span>
      </div>

      <div class="mt-4 text-center min-w-0 w-full">
        <div class={[
          "font-semibold text-heading truncate",
          (@rank == 1 && "text-sm") || "text-xs"
        ]}>
          <%= @user.display_name || @user.username %>
        </div>
        <div class={[
          "font-bold tabular-nums text-accent",
          (@rank == 1 && "text-xl") || "text-base"
        ]}>
          <%= @user.score %>
        </div>
      </div>
    </.link>
    """
  end

  # The winner is bigger, which is what makes it read as a podium at a glance.
  defp avatar_size(1), do: "w-20 h-20 sm:w-24 sm:h-24"
  defp avatar_size(_), do: "w-16 h-16 sm:w-20 sm:h-20"

  defp ring_class(1), do: "ring-amber-400"
  defp ring_class(2), do: "ring-slate-400"
  defp ring_class(_), do: "ring-amber-700"

  defp badge_class(1), do: "bg-amber-400 text-amber-950"
  defp badge_class(2), do: "bg-slate-400 text-slate-950"
  defp badge_class(_), do: "bg-amber-700 text-amber-50"

  defp initial(user) do
    (user.display_name || user.username) |> String.slice(0..0) |> String.upcase()
  end

end
