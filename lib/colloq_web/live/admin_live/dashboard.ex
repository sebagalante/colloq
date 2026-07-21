defmodule ColloqWeb.AdminLive.Dashboard do
  use ColloqWeb, :live_view

  import Ecto.Query

  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Forum.{Post, Topic, Category}
  alias Colloq.Moderation
  alias Colloq.Moderation.Flag
  alias Colloq.Reactions.Reaction
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
    |> assign(:kpis, compute_kpis(range))
    |> assign(:online_users, online_users_count())
    |> assign(:user_growth_data, daily_count_series(User, range))
    |> assign(:post_activity_data, daily_count_series(Post, range))
    |> assign(:active_users_data, daily_active_series(range))
    |> assign(:category_activity_data, category_activity_chart_data())
    |> assign(:flags_by_reason_data, flags_by_reason_chart_data())
    |> assign(:reaction_distribution, reaction_distribution_data())
    |> assign(:flags_count, recent_flags_count())
    |> assign(:recent_flags, recent_flags())
    |> assign(:worker_health, Colloq.WorkerHealth.by_worker(since: worker_window(range)))
    |> assign(:worker_totals, Colloq.WorkerHealth.totals(since: worker_window(range)))
    |> assign(:worker_failures, Colloq.WorkerHealth.recent_failures(6))
  end

  # Background jobs follow the dashboard's range selector like every other
  # panel, so "last 7 days" means the same thing everywhere on the page.
  defp worker_window(range_days) do
    NaiveDateTime.add(NaiveDateTime.utc_now(), -range_days * 24 * 3600, :second)
  end

  defp refresh_flags(socket) do
    socket
    |> assign(:recent_flags, recent_flags())
    |> assign(:flags_count, recent_flags_count())
  end

  # --- KPIs ------------------------------------------------------------------

  defp compute_kpis(range) do
    {cur_start, prev_start, now} = period_bounds(range)

    [
      registrations_kpi(cur_start, prev_start, now),
      new_contributors_kpi(cur_start, prev_start, now),
      active_contributors_kpi(cur_start, prev_start, now),
      posts_kpi(cur_start, prev_start, now),
      dau_mau_kpi()
    ]
  end

  defp period_bounds(range) do
    now = DateTime.utc_now()
    {DateTime.add(now, -range, :day), DateTime.add(now, -2 * range, :day), now}
  end

  defp registrations_kpi(cur_start, prev_start, now) do
    cur = inserted_count(User, cur_start, now)
    prev = inserted_count(User, prev_start, cur_start)
    total = Repo.aggregate(User, :count)

    trend_kpi("reg", gettext("New registrations"), cur, prev,
      daily_count_series(User, cur_start),
      gettext("%{n} total", n: total)
    )
  end

  defp posts_kpi(cur_start, prev_start, now) do
    cur = inserted_count(Post, cur_start, now)
    prev = inserted_count(Post, prev_start, cur_start)
    total = Repo.aggregate(Post, :count)

    trend_kpi("posts", gettext("New posts"), cur, prev,
      daily_count_series(Post, cur_start),
      gettext("%{n} total", n: total)
    )
  end

  defp active_contributors_kpi(cur_start, prev_start, now) do
    cur = distinct_posters(cur_start, now)
    prev = distinct_posters(prev_start, cur_start)

    trend_kpi("active", gettext("Active contributors"), cur, prev,
      daily_active_series_from(cur_start), nil)
  end

  # Users whose *first-ever* post falls in the period.
  defp new_contributors_kpi(cur_start, prev_start, now) do
    cur = first_posters_between(cur_start, now)
    prev = first_posters_between(prev_start, cur_start)

    trend_kpi("new-contrib", gettext("New contributors"), cur, prev,
      first_posters_series(cur_start), nil)
  end

  # DAU/MAU stickiness: distinct members active in the last day vs last 30 days.
  # (Members = posters; anonymous reads aren't tracked, so this is member DAU/MAU.)
  defp dau_mau_kpi do
    now = DateTime.utc_now()
    dau = distinct_posters(DateTime.add(now, -1, :day), now)
    mau = distinct_posters(DateTime.add(now, -30, :day), now)
    ratio = if mau > 0, do: round(dau / mau * 100), else: 0

    %{
      id: "dau-mau",
      label: "DAU/MAU",
      value: "#{ratio}%",
      delta: nil,
      spark: nil,
      sub: gettext("%{dau} today / %{mau} in 30d", dau: dau, mau: mau)
    }
  end

  defp trend_kpi(id, label, value, prev, spark, sub) do
    delta = if prev > 0, do: round((value - prev) / prev * 100), else: nil
    %{id: id, label: label, value: value, delta: delta, spark: spark, sub: sub}
  end

  # --- KPI queries -----------------------------------------------------------

  defp inserted_count(schema, a, b) do
    Repo.aggregate(from(x in schema, where: x.inserted_at >= ^a and x.inserted_at < ^b), :count)
  end

  defp distinct_posters(a, b) do
    Repo.one(
      from(p in Post, where: p.inserted_at >= ^a and p.inserted_at < ^b, select: count(p.user_id, :distinct))
    ) || 0
  end

  defp first_posts_query do
    from(p in Post, group_by: p.user_id, select: %{user_id: p.user_id, first: min(p.inserted_at)})
  end

  defp first_posters_between(a, b) do
    Repo.one(
      from(f in subquery(first_posts_query()),
        where: f.first >= ^a and f.first < ^b,
        select: count(f.user_id)
      )
    ) || 0
  end

  # --- Chart series ----------------------------------------------------------

  # New rows/day over the last `range` days (registrations, posts, growth).
  defp daily_count_series(schema, range) when is_integer(range) do
    daily_count_series(schema, DateTime.add(DateTime.utc_now(), -range, :day))
  end

  defp daily_count_series(schema, %DateTime{} = start) do
    from(x in schema,
      where: x.inserted_at >= ^start,
      group_by: fragment("date_trunc('day', ?)", x.inserted_at),
      order_by: fragment("date_trunc('day', ?)", x.inserted_at),
      select: {fragment("date_trunc('day', ?)", x.inserted_at), count(x.id)}
    )
    |> Repo.all()
    |> encode_series()
  end

  # Distinct posters/day.
  defp daily_active_series(range), do: daily_active_series_from(DateTime.add(DateTime.utc_now(), -range, :day))

  defp daily_active_series_from(%DateTime{} = start) do
    from(p in Post,
      where: p.inserted_at >= ^start,
      group_by: fragment("date_trunc('day', ?)", p.inserted_at),
      order_by: fragment("date_trunc('day', ?)", p.inserted_at),
      select: {fragment("date_trunc('day', ?)", p.inserted_at), count(p.user_id, :distinct)}
    )
    |> Repo.all()
    |> encode_series()
  end

  # First-posts/day (new contributors sparkline).
  defp first_posters_series(%DateTime{} = start) do
    from(f in subquery(first_posts_query()),
      where: f.first >= ^start,
      group_by: fragment("date_trunc('day', ?)", f.first),
      order_by: fragment("date_trunc('day', ?)", f.first),
      select: {fragment("date_trunc('day', ?)", f.first), count(f.user_id)}
    )
    |> Repo.all()
    |> encode_series()
  end

  defp encode_series(rows) do
    Enum.map_join(rows, ",", fn {date, count} -> "#{Date.to_string(date)}|#{count}" end)
  end

  # --- Distribution charts (not time-windowed) -------------------------------

  defp category_activity_chart_data do
    from(t in Topic,
      join: c in Category,
      on: c.id == t.category_id,
      group_by: c.name,
      order_by: [desc: count(t.id)],
      limit: 10,
      select: {c.name, count(t.id)}
    )
    |> Repo.all()
    |> Enum.map_join(",", fn {name, count} -> "#{chart_label(name)}|#{count}" end)
  end

  defp flags_by_reason_chart_data do
    from(f in Flag,
      group_by: f.reason,
      order_by: [desc: count(f.id)],
      select: {f.reason, count(f.id)}
    )
    |> Repo.all()
    |> Enum.map_join(",", fn {reason, count} -> "#{chart_label(reason)}|#{count}" end)
  end

  defp reaction_distribution_data do
    from(r in Reaction,
      group_by: r.emoji,
      order_by: [desc: count(r.id)],
      limit: 10,
      select: {r.emoji, count(r.id)}
    )
    |> Repo.all()
    |> Enum.map_join(",", fn {emoji, count} -> "#{emoji}|#{count}" end)
  end

  # Chart labels are packed into a "label|value,..." string, so a label may not
  # contain the "," or "|" separators.
  defp chart_label(nil), do: "—"
  defp chart_label(label), do: label |> to_string() |> String.replace([",", "|"], " ")

  # --- Misc stats & flags ----------------------------------------------------

  # Actually-connected users, from the Presence tracker (LiveView sockets) — not
  # `updated_at`, which only changes on a row write and so is ~always 0.
  defp online_users_count, do: ColloqWeb.Presence.online_ids() |> MapSet.size()

  defp recent_flags_count do
    Repo.aggregate(from(f in Flag, where: f.resolved == false), :count)
  end

  defp recent_flags do
    Moderation.list_pending_flags()
    |> Enum.take(10)
    |> Enum.map(fn flag ->
      post = if Ecto.assoc_loaded?(flag.post), do: flag.post, else: nil

      %{
        id: flag.id,
        reason: flag.reason,
        inserted_at: flag.inserted_at,
        post_id: flag.post_id,
        topic_id: post && post.topic_id,
        deleted: post && post.deleted_at != nil,
        excerpt: post && flag_excerpt(post.body),
        user: if(Ecto.assoc_loaded?(flag.user) && flag.user, do: flag.user.username, else: nil)
      }
    end)
  end

  defp flag_excerpt(nil), do: ""
  defp flag_excerpt(body), do: body |> HtmlSanitizeEx.strip_tags() |> String.trim() |> String.slice(0, 160)

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
