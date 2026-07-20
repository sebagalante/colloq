defmodule ColloqWeb.PlayerCardLive do
  @moduledoc """
  Player career table: search a player, then see every season aggregated by year
  (matches played, minutes, goals, assists) across all competitions, with rows
  you can expand to reveal the per-competition breakdown.

  Data comes from `Colloq.Sofascore.player_career/1` (Sofascore), fetched via
  `start_async` so the fan-out of stats calls never blocks the socket.
  """
  use ColloqWeb, :live_view

  alias Colloq.Sofascore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Player stats"))
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:player, nil)
     |> assign(:career, nil)
     |> assign(:expanded, MapSet.new())
     |> assign(:loading, false)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    results =
      case String.trim(query) do
        "" -> []
        q -> Sofascore.search(q) |> Enum.take(8)
      end

    {:noreply, socket |> assign(:query, query) |> assign(:results, results)}
  end

  def handle_event("pick", %{"id" => sofascore_id}, socket) do
    case Sofascore.get_player(sofascore_id) do
      nil ->
        {:noreply, socket}

      player ->
        {:noreply,
         socket
         |> assign(:player, player)
         |> assign(:results, [])
         |> assign(:query, "")
         |> assign(:career, nil)
         |> assign(:expanded, MapSet.new())
         |> assign(:error, nil)
         |> assign(:loading, true)
         |> start_async(:career, fn -> Sofascore.player_career(player) end)}
    end
  end

  def handle_event("toggle-year", %{"year" => year}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, year),
        do: MapSet.delete(expanded, year),
        else: MapSet.put(expanded, year)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  @impl true
  def handle_async(:career, {:ok, {:ok, career}}, socket) do
    {:noreply, socket |> assign(:career, career) |> assign(:loading, false)}
  end

  def handle_async(:career, _result, socket) do
    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:error, gettext("Couldn't load stats for this player right now."))}
  end

  defp team_crest(team_id), do: "https://api.sofascore.com/api/v1/team/#{team_id}/image"
  defp tournament_crest(id), do: "https://api.sofascore.com/api/v1/unique-tournament/#{id}/image"
  defp player_photo(id), do: "https://api.sofascore.com/api/v1/player/#{id}/image"

  # Thousands separator (Spanish/European "."): 2288 -> "2.288".
  defp fmt(n) when is_integer(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ".")
  end

  defp fmt(n), do: to_string(n)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 py-6">
      <h1 class="text-2xl font-bold text-heading mb-1"><%= gettext("Player stats") %></h1>
      <p class="text-sm text-muted mb-5">
        <%= gettext("Search a player to see their full career by season.") %>
      </p>

      <form phx-change="search" phx-submit="search" class="relative mb-5">
        <input
          type="text"
          name="query"
          value={@query}
          autocomplete="off"
          placeholder={gettext("Search a player…")}
          class="w-full rounded-lg bg-surface border border-border px-4 py-2.5 text-sm text-body placeholder:text-muted focus:border-accent focus:outline-none"
        />
        <div
          :if={@results != []}
          class="absolute z-20 left-0 right-0 mt-1 rounded-lg bg-surface border border-border shadow-lg py-1 max-h-80 overflow-y-auto"
        >
          <button
            :for={p <- @results}
            type="button"
            phx-click="pick"
            phx-value-id={p.sofascore_id}
            class="flex items-center gap-3 w-full text-left px-3 py-2 hover:bg-surface-alt transition-colors"
          >
            <img src={player_photo(p.sofascore_id)} alt="" class="w-8 h-8 rounded-full object-cover bg-surface-alt flex-shrink-0" loading="lazy" />
            <span class="min-w-0">
              <span class="block text-sm font-medium text-heading truncate"><%= p.name %></span>
              <span :if={p.position} class="block text-xs text-muted truncate"><%= p.position %></span>
            </span>
          </button>
        </div>
      </form>

      <%!-- Selected player header --%>
      <div :if={@player} class="flex items-center gap-3 mb-4">
        <img src={player_photo(@player.sofascore_id)} alt="" class="w-12 h-12 rounded-full object-cover bg-surface-alt" />
        <div>
          <div class="text-lg font-bold text-heading"><%= @player.name %></div>
          <div :if={@player.position} class="text-xs text-muted"><%= @player.position %></div>
        </div>
      </div>

      <div :if={@loading} class="py-16 text-center text-sm text-muted"><%= gettext("Loading stats…") %></div>
      <div :if={!@loading && @error} class="py-16 text-center text-sm text-danger"><%= @error %></div>

      <%!-- Career table --%>
      <div :if={!@loading && !@error && @career} class="overflow-x-auto rounded-xl border border-border">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-[11px] uppercase tracking-wide text-muted bg-surface-alt/60">
              <th class="text-left font-medium px-3 py-2"><%= gettext("Year") %></th>
              <th class="text-left font-medium px-2 py-2"><%= gettext("Team") %></th>
              <th class="text-right font-medium px-2 py-2">PJ</th>
              <th class="text-right font-medium px-2 py-2">MIN</th>
              <th class="text-right font-medium px-2 py-2">GOL</th>
              <th class="text-right font-medium px-3 py-2">ASIS</th>
            </tr>
          </thead>
          <tbody>
            <%= for row <- @career.rows do %>
              <tr
                phx-click="toggle-year"
                phx-value-year={row.year}
                class="border-t border-border cursor-pointer hover:bg-surface-alt/50 transition-colors"
              >
                <td class="px-3 py-2.5 font-semibold text-heading whitespace-nowrap">
                  <span class="inline-flex items-center gap-1">
                    <.icon
                      name="chevron-down"
                      class={[
                        "w-3.5 h-3.5 text-muted transition-transform",
                        !MapSet.member?(@expanded, row.year) && "-rotate-90"
                      ]}
                    /><%= row.year %>
                  </span>
                </td>
                <td class="px-2 py-2.5">
                  <span class="flex items-center gap-1">
                    <img :for={{tid, _name} <- Enum.take(row.teams, 3)} src={team_crest(tid)} alt="" class="w-5 h-5 object-contain" loading="lazy" />
                  </span>
                </td>
                <td class="px-2 py-2.5 text-right tabular-nums text-body"><%= row.mp %></td>
                <td class="px-2 py-2.5 text-right tabular-nums text-body"><%= fmt(row.min) %></td>
                <td class="px-2 py-2.5 text-right tabular-nums text-body"><%= row.gls %></td>
                <td class="px-3 py-2.5 text-right tabular-nums text-body"><%= row.ast %></td>
              </tr>
              <%= if MapSet.member?(@expanded, row.year) do %>
                <tr :for={c <- row.competitions} class="border-t border-border/40 bg-surface-alt/30 text-muted">
                  <td class="px-3 py-2"></td>
                  <td class="px-2 py-2" colspan="1">
                    <span class="flex items-center gap-2">
                      <img src={tournament_crest(c.tournament_id)} alt="" class="w-4 h-4 object-contain flex-shrink-0" loading="lazy" />
                      <span class="text-xs text-body truncate"><%= c.tournament_name %></span>
                    </span>
                  </td>
                  <td class="px-2 py-2 text-right tabular-nums text-xs"><%= c.mp %></td>
                  <td class="px-2 py-2 text-right tabular-nums text-xs"><%= fmt(c.min) %></td>
                  <td class="px-2 py-2 text-right tabular-nums text-xs"><%= c.gls %></td>
                  <td class="px-3 py-2 text-right tabular-nums text-xs"><%= c.ast %></td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>

      <div :if={!@loading && !@error && !@career && !@player} class="py-16 text-center text-sm text-muted">
        <%= gettext("Search a player to see their stats.") %>
      </div>
    </div>
    """
  end
end
