defmodule ColloqWeb.AdminLive.Sofascore do
  @moduledoc """
  Admin panel to trigger Sofascore data refreshes on demand. Each button
  enqueues an Oban job on the :scorebot queue via `Colloq.Sofascore`; the
  worker runs asynchronously (watch the logs for results).
  """
  use ColloqWeb, :live_view

  alias Colloq.Sofascore

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Sofascore"))
      |> assign(:season_id, Sofascore.current_season_id())
      |> assign(:last_runs, %{})

    {:ok, socket}
  end

  @impl true
  def handle_event("save-season", %{"season_id" => season_id}, socket) do
    case Integer.parse(String.trim(season_id)) do
      {id, _} when id > 0 ->
        Colloq.SiteSettings.put("sofascore_season_id", id,
          type: "integer",
          group: "match_day",
          description: "ID de temporada de Sofascore (Liga Profesional, torneo 155)"
        )

        {:noreply,
         socket
         |> assign(:season_id, id)
         |> put_flash(:info, gettext("Season id saved."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Enter a valid numeric season id."))}
    end
  end

  def handle_event("refresh-racing-fixtures", _params, socket) do
    Sofascore.refresh_fixtures(Sofascore.racing_team_id())
    {:noreply, ran(socket, "racing_fixtures")}
  end

  def handle_event("refresh-all-fixtures", _params, socket) do
    Sofascore.refresh_fixtures()
    {:noreply, ran(socket, "all_fixtures")}
  end

  def handle_event("refresh-squads", _params, socket) do
    Sofascore.refresh_squads()
    {:noreply, ran(socket, "squads")}
  end

  def handle_event("refresh-standings", _params, socket) do
    case socket.assigns.season_id do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Set the season id first (Settings ▸ Match Day ▸ sofascore_season_id).")
         )}

      season_id ->
        Sofascore.refresh_standings(season_id)
        {:noreply, ran(socket, "standings")}
    end
  end

  # Record an enqueue timestamp for the given action and flash a confirmation.
  defp ran(socket, key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    socket
    |> update(:last_runs, &Map.put(&1, key, now))
    |> put_flash(:info, gettext("Job enqueued. Watch the logs for the result."))
  end

  def last_run(last_runs, key) do
    case Map.get(last_runs, key) do
      nil -> nil
      dt -> Calendar.strftime(dt, "%H:%M:%S UTC")
    end
  end

  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :event, :string, required: true
  attr :last, :string, default: nil
  attr :disabled, :boolean, default: false

  def sofascore_action(assigns) do
    ~H"""
    <div class="flex items-center gap-4 p-4 rounded-lg bg-surface border border-border">
      <div class="flex-1 min-w-0">
        <div class="font-semibold text-heading"><%= @title %></div>
        <p class="text-xs text-muted mt-0.5"><%= @desc %></p>
        <p :if={@last} class="text-xs text-accent mt-1">
          <%= gettext("Last enqueued:") %> <%= @last %>
        </p>
      </div>
      <.button phx-click={@event} disabled={@disabled} class="text-sm shrink-0">
        <%= gettext("Run") %>
      </.button>
    </div>
    """
  end
end
