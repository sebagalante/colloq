defmodule ColloqWeb.AdminLive.Dashboard do
  use ColloqWeb, :live_view

  alias Colloq.Repo
  alias Colloq.Forum.Post
  alias Colloq.Moderation
  alias Colloq.Admin.DashboardData
  alias Phoenix.PubSub

  # Selectable date ranges (days) for the period KPIs and time-series charts.
  @ranges [7, 30, 90]
  @default_range 30

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_dashboard(socket, @default_range)

    if connected?(socket), do: PubSub.subscribe(Colloq.PubSub, "admin:dashboard")

    {:ok, socket}
  end

  @impl true
  def handle_event("set-range", %{"days" => days}, socket) do
    range = if String.to_integer(days) in @ranges, do: String.to_integer(days), else: @default_range
    {:noreply, assign_dashboard(socket, range)}
  end

  # Dismiss a report without hiding the post.
  def handle_event("dismiss-flag", %{"id" => id}, socket) do
    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "dismissed")
    {:noreply, socket |> refresh_flags() |> put_flash(:info, gettext("Report dismissed."))}
  end

  # Hide the reported post and resolve the report.
  def handle_event("hide-flagged-post", %{"id" => id, "post_id" => post_id}, socket) do
    case Repo.get(Post, String.to_integer(post_id)) do
      nil -> :ok
      post -> Moderation.hide_post(post)
    end

    Moderation.resolve_flag(String.to_integer(id), socket.assigns.current_user.id, "post_hidden")
    {:noreply, socket |> refresh_flags() |> put_flash(:info, gettext("Post hidden and report resolved."))}
  end

  @impl true
  # Live-ish signals (online count, flag queue) refresh on any dashboard event;
  # the period KPIs are recomputed on mount / range change, not per-event.
  def handle_info({:dashboard_refresh, _payload}, socket) do
    {:noreply, refresh_flags(socket) |> assign(:online_users, online_users_count())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Assign orchestration --------------------------------------------------

  defp assign_dashboard(socket, range) do
    socket
    |> assign(:page_title, "Panel de Control")
    |> assign(:ranges, @ranges)
    |> assign(:range_days, range)
    |> assign(:kpis, DashboardData.kpis(range))
    |> assign(:online_users, online_users_count())
    |> assign(:user_growth_data, DashboardData.user_growth_series(range))
    |> assign(:post_activity_data, DashboardData.post_activity_series(range))
    |> assign(:active_users_data, DashboardData.contributors_series(range))
    |> assign(:category_activity_data, DashboardData.category_activity())
    |> assign(:flags_by_reason_data, DashboardData.flags_by_reason())
    |> assign(:reaction_distribution, DashboardData.reaction_distribution())
    |> assign(:flags_count, DashboardData.recent_flags_count())
    |> assign(:recent_flags, DashboardData.recent_flags())
    |> assign(:worker_health, Colloq.WorkerHealth.by_worker(since: worker_window(range)))
    |> assign(:worker_totals, Colloq.WorkerHealth.totals(since: worker_window(range)))
    |> assign(:worker_failures, Colloq.WorkerHealth.recent_failures(6))
    |> assign(:recent_logins, Colloq.Accounts.recent_logins(8))
  end

  # Background jobs follow the dashboard's range selector like every other
  # panel, so "last 7 days" means the same thing everywhere on the page.
  defp worker_window(range_days) do
    NaiveDateTime.add(NaiveDateTime.utc_now(), -range_days * 24 * 3600, :second)
  end

  defp refresh_flags(socket) do
    socket
    |> assign(:recent_flags, DashboardData.recent_flags())
    |> assign(:flags_count, DashboardData.recent_flags_count())
  end

  # --- Misc stats ------------------------------------------------------------

  # Actually-connected users, from the Presence tracker (LiveView sockets) — not
  # `updated_at`, which only changes on a row write and so is ~always 0.
  defp online_users_count, do: ColloqWeb.Presence.online_ids() |> MapSet.size()

  # --- KPI tile component ----------------------------------------------------

  attr :kpi, :map, required: true

  def kpi_tile(assigns) do
    ~H"""
    <.card>
      <p class="text-sm text-muted"><%= @kpi.label %></p>
      <div class="flex items-baseline justify-between gap-2 mt-1">
        <p class="text-3xl font-bold text-heading tabular-nums"><%= @kpi.value %></p>
        <span :if={@kpi.delta != nil} class={["text-xs font-semibold tabular-nums", delta_class(@kpi.delta)]}>
          <%= delta_label(@kpi.delta) %>
        </span>
      </div>
      <div
        :if={@kpi.spark && @kpi.spark != ""}
        id={"spark-#{@kpi.id}"}
        phx-hook="ECharts"
        data-chart-type="spark"
        data-chart-data={@kpi.spark}
        class="h-8 mt-2"
      >
      </div>
      <p :if={@kpi.sub} class="text-xs text-muted mt-1"><%= @kpi.sub %></p>
    </.card>
    """
  end

  defp delta_class(d) when d > 0, do: "text-emerald-400"
  defp delta_class(d) when d < 0, do: "text-red-400"
  defp delta_class(_), do: "text-muted"

  defp delta_label(d) when d > 0, do: "▲ #{d}%"
  defp delta_label(d) when d < 0, do: "▼ #{abs(d)}%"
  defp delta_label(_), do: "0%"
end
