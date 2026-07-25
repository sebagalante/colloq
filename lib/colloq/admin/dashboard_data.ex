defmodule Colloq.Admin.DashboardData do
  @moduledoc """
  Read-only queries behind the admin dashboard.

  Extracted from `ColloqWeb.AdminLive.Dashboard` so the numbers can be tested
  without standing up a LiveView (admin routes sit behind a 2FA gate, which
  makes end-to-end tests awkward — a plain context does not).

  Everything here is a pure query returning data or the chart-encoded string
  the ECharts hook expects (`"label|value,label|value"`); presentation — tiles,
  colours, deltas — stays in the web layer.
  """

  import Ecto.Query
  import ColloqWeb.Gettext

  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Forum.{Post, Topic, Category}
  alias Colloq.Moderation
  alias Colloq.Moderation.Flag
  alias Colloq.Reactions.Reaction

  # --- KPIs ------------------------------------------------------------------

  @doc """
  The KPI tiles for a range (days): registrations, new/active contributors,
  posts, and DAU/MAU. Each is a map the tile component renders as-is:
  `%{id, label, value, delta, spark, sub}`.
  """
  def kpis(range) do
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

  @doc "New registrations/day over the last `range` days, chart-encoded."
  def user_growth_series(range), do: daily_count_series(User, range)

  @doc "New posts/day over the last `range` days, chart-encoded."
  def post_activity_series(range), do: daily_count_series(Post, range)

  @doc "Distinct posters/day over the last `range` days, chart-encoded."
  def contributors_series(range), do: daily_active_series(range)

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

  @doc "Top 10 categories by topic count, chart-encoded."
  def category_activity do
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

  @doc "Flag counts grouped by reason, chart-encoded."
  def flags_by_reason do
    from(f in Flag,
      group_by: f.reason,
      order_by: [desc: count(f.id)],
      select: {f.reason, count(f.id)}
    )
    |> Repo.all()
    |> Enum.map_join(",", fn {reason, count} -> "#{chart_label(reason)}|#{count}" end)
  end

  @doc "Top 10 reactions by emoji, chart-encoded."
  def reaction_distribution do
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

  # --- Flags -----------------------------------------------------------------

  @doc "Count of unresolved reports."
  def recent_flags_count do
    Repo.aggregate(from(f in Flag, where: f.resolved == false), :count)
  end

  @doc "Up to 10 pending reports, flattened for the queue view."
  def recent_flags do
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
end
