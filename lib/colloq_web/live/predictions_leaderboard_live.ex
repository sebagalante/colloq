defmodule ColloqWeb.PredictionsLeaderboardLive do
  @moduledoc """
  Full prode standings for the current season.

  Split out of `ColloqWeb.PredictionsLive`, which used to render a 20-row card
  under the round form and re-ran the aggregate on every round navigation. Here
  the table is the page: deeper (`@limit` rows), with the average-points column
  the query has always computed but the card never showed.
  """
  use ColloqWeb, :live_view

  import ColloqWeb.Components.Prode, only: [scoring_rules: 1]

  alias Colloq.{Predictions, Sofascore}

  # Deep enough to hold every regular player without paginating.
  @limit 100

  @impl true
  def mount(_params, _session, socket) do
    season_id = Sofascore.current_season_id()

    {:ok,
     socket
     |> assign(:page_title, pgettext("prode", "Prode standings"))
     |> assign(:season_id, season_id)
     |> assign(:entries, load_entries(season_id))}
  end

  # Scored by PredictionScorerWorker after each match, so a table left open goes
  # stale silently; a manual refresh beats polling for a page nobody watches
  # live.
  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :entries, load_entries(socket.assigns.season_id))}
  end

  defp load_entries(nil), do: []
  defp load_entries(season_id), do: Predictions.leaderboard(season: season_id, limit: @limit)

  # The user's own row, so they can find themselves without scanning 100 rows.
  defp own_rank(_entries, nil), do: nil

  defp own_rank(entries, user) do
    case Enum.find_index(entries, &(&1.user_id == user.id)) do
      nil -> nil
      idx -> {idx + 1, Enum.at(entries, idx)}
    end
  end

  # avg(points) comes back as a Decimal (or nil for a user with no scored rows).
  defp format_average(nil), do: "—"
  defp format_average(%Decimal{} = avg), do: avg |> Decimal.round(2) |> Decimal.to_string()
  defp format_average(avg) when is_float(avg), do: :erlang.float_to_binary(avg, decimals: 2)
  defp format_average(avg), do: to_string(avg)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :own, own_rank(assigns.entries, assigns[:current_user]))

    ~H"""
    <section class="space-y-6">
      <div class="flex items-center justify-between gap-3">
        <h1 class="text-2xl font-bold text-heading flex items-center gap-2">
          <.icon name="award" class="w-6 h-6 text-accent" />
          <%= pgettext("prode", "Prode standings") %>
        </h1>
        <.link
          navigate={~p"/predicciones"}
          class="text-sm text-accent hover:underline whitespace-nowrap"
        >
          ← <%= pgettext("prode", "Predictions") %>
        </.link>
      </div>

      <%= if is_nil(@season_id) do %>
        <.card>
          <p class="text-sm text-muted">
            <%= gettext(
              "The league isn't configured yet (missing season id). Ask an admin to set it in Settings ▸ Match Day."
            ) %>
          </p>
        </.card>
      <% else %>
        <.card>
          <div class="flex items-center justify-between mb-3">
            <p class="text-sm text-muted">
              <%= gettext("Ranked by total points across every scored match this season.") %>
            </p>
            <button
              type="button"
              phx-click="refresh"
              class="px-3 py-1.5 rounded-md text-sm bg-surface-alt text-body hover:text-heading whitespace-nowrap"
            >
              <%= pgettext("prode", "Update standings") %>
            </button>
          </div>

          <p :if={@own} class="text-sm text-body mb-3">
            <%= gettext("You are ranked %{rank} with %{points} points.",
              rank: elem(@own, 0),
              points: elem(@own, 1).total_points
            ) %>
          </p>

          <%= if @entries == [] do %>
            <p class="text-sm text-muted">
              <%= gettext("No scored predictions this season yet.") %>
            </p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-border">
                    <th class="text-left py-2 px-3 text-muted font-medium w-10">#</th>
                    <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("User") %></th>
                    <th class="text-center py-2 px-3 text-muted font-medium"><%= gettext("Points") %></th>
                    <th class="text-center py-2 px-3 text-muted font-medium">
                      <%= gettext("Predictions") %>
                    </th>
                    <th class="text-center py-2 px-3 text-muted font-medium">
                      <%= gettext("Average") %>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {entry, rank} <- Enum.with_index(@entries, 1) do %>
                    <tr class={[
                      "border-b border-border/50",
                      @current_user && entry.user_id == @current_user.id && "bg-surface-alt"
                    ]}>
                      <td class="py-2 px-3 text-muted">
                        <%= if rank <= 3 do %>
                          <.badge color="amber"><%= rank %></.badge>
                        <% else %>
                          <span class="text-muted"><%= rank %></span>
                        <% end %>
                      </td>
                      <td class="py-2 px-3 text-heading font-medium">
                        <%= if entry.user do %>
                          <.link navigate={~p"/u/#{entry.user.username}"} class="hover:underline">
                            <%= entry.user.username %>
                          </.link>
                        <% else %>
                          <%= gettext("User #%{id}", id: entry.user_id) %>
                        <% end %>
                      </td>
                      <td class="py-2 px-3 text-center text-heading font-bold tabular-nums">
                        <%= entry.total_points %>
                      </td>
                      <td class="py-2 px-3 text-center text-muted tabular-nums">
                        <%= entry.predictions_count %>
                      </td>
                      <td class="py-2 px-3 text-center text-muted tabular-nums">
                        <%= format_average(entry.average_points) %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </.card>

        <%!-- Below the table: someone reading the standings is exactly who asks
              "why did I get 4 points for that?" --%>
        <.scoring_rules />
      <% end %>
    </section>
    """
  end
end
