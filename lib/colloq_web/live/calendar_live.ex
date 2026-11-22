defmodule ColloqWeb.CalendarLive do
  @moduledoc """
  `/calendario`: a week of matches for Racing, the Selección and the Liga
  Profesional, each linked to its match thread when the forum has one.

  Week grid on desktop, day-by-day list on phones (seven columns don't fit a
  phone, and squeezing them is how cards end up reading "Fi / na / l").
  The week lives in the URL (`?semana=2026-11-09`) so it can be linked and the
  back button steps through weeks; the filters live in the socket and survive
  week changes.
  """
  use ColloqWeb, :live_view

  alias Colloq.Calendar

  @live_refresh :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Calendar"))
     |> assign(:enabled, Calendar.default_filter_keys())
     |> assign(:refresh_ref, nil)
     |> assign(:week, nil)
     |> assign(:days, [])
     |> assign(:counts, %{})
     |> assign(:threads, %{})}
  end

  # The week is fetched off the LiveView process: a day FotMob hasn't served
  # lately takes it up to ~20 s, and the page (filters, week buttons) should
  # stay usable meanwhile. The static render shows the loading state and never
  # fetches, so a crawler or a cold first load can't hold a request open.
  @impl true
  def handle_params(params, _uri, socket) do
    monday = Calendar.week_start(param_date(params["semana"]) || Calendar.today())
    socket = socket |> assign(:monday, monday) |> assign(:week, nil)
    {:noreply, if(connected?(socket), do: fetch_week(socket), else: socket)}
  end

  defp fetch_week(socket) do
    monday = socket.assigns.monday
    start_async(socket, :week, fn -> {monday, Calendar.week(monday)} end)
  end

  @impl true
  def handle_async(:week, {:ok, {monday, week}}, socket) do
    # A result for a week the reader already navigated away from is dropped.
    if monday == socket.assigns.monday,
      do: {:noreply, load_week(socket, week)},
      else: {:noreply, socket}
  end

  def handle_async(:week, {:exit, _reason}, socket) do
    {:noreply, load_week(socket, %{days: empty_days(socket.assigns.monday), stale?: false, failed?: true})}
  end

  defp empty_days(monday), do: Enum.map(0..6, &{Date.add(monday, &1), []})

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    enabled =
      if key in socket.assigns.enabled,
        do: List.delete(socket.assigns.enabled, key),
        else: [key | socket.assigns.enabled]

    socket = assign(socket, :enabled, enabled)
    {:noreply, if(socket.assigns.week, do: assign_visible(socket), else: socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, fetch_week(socket)}

  defp load_week(socket, week) do
    all = Enum.flat_map(week.days, &elem(&1, 1))

    socket
    |> assign(:week, week)
    |> assign(:counts, Calendar.counts(all))
    |> assign_visible()
    |> schedule_refresh()
  end

  defp assign_visible(socket) do
    days =
      Enum.map(socket.assigns.week.days, fn {date, matches} ->
        {date, Calendar.filter(matches, socket.assigns.enabled)}
      end)

    visible = Enum.flat_map(days, &elem(&1, 1))

    socket
    |> assign(:days, days)
    |> assign(:threads, Calendar.match_threads(visible))
  end

  # Re-read the week every minute while something in it is being played, so a
  # live score moves without a reload. The day cache has a 1-minute TTL then,
  # so this costs FotMob one request per minute however many people watch.
  defp schedule_refresh(socket) do
    if ref = socket.assigns.refresh_ref, do: Process.cancel_timer(ref)

    live? =
      Enum.any?(socket.assigns.week.days, fn {_, ms} ->
        Enum.any?(ms, &(&1.status in [:live, :halftime]))
      end)

    ref = if connected?(socket) and live?, do: Process.send_after(self(), :refresh, @live_refresh)
    assign(socket, :refresh_ref, ref)
  end

  defp param_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp param_date(_), do: nil

  # --- View helpers ----------------------------------------------------------------

  def week_path(monday), do: ~p"/calendario?semana=#{Date.to_iso8601(monday)}"

  def filter_label("racing"), do: "Racing"
  def filter_label("argentina"), do: gettext("Argentina national team")
  def filter_label("liga"), do: "Liga Profesional"
  def filter_label("primera_nacional"), do: "Primera Nacional"
  def filter_label("copa_argentina"), do: "Copa Argentina"
  def filter_label("libertadores"), do: "Libertadores"
  def filter_label("sudamericana"), do: "Sudamericana"
  def filter_label("champions"), do: "Champions League"
  def filter_label("premier"), do: "Premier League"
  def filter_label("laliga"), do: "La Liga"
  def filter_label("serie_a"), do: "Serie A"
  def filter_label("bundesliga"), do: "Bundesliga"

  # Card accent and checkbox colour per filter. Full class names, so Tailwind
  # finds them in the source.
  def filter_color("racing"), do: "bg-sky-400"
  def filter_color("argentina"), do: "bg-indigo-400"
  def filter_color("liga"), do: "bg-emerald-500"
  def filter_color("primera_nacional"), do: "bg-pink-500"
  def filter_color("copa_argentina"), do: "bg-teal-400"
  def filter_color("libertadores"), do: "bg-amber-500"
  def filter_color("sudamericana"), do: "bg-lime-500"
  def filter_color("champions"), do: "bg-blue-600"
  def filter_color("premier"), do: "bg-purple-500"
  def filter_color("laliga"), do: "bg-[var(--orange)]"
  def filter_color("serie_a"), do: "bg-cyan-600"
  def filter_color("bundesliga"), do: "bg-red-500"
  def filter_color(_), do: "bg-border"

  def day_name(date) do
    case Date.day_of_week(date) do
      1 -> gettext("Mon")
      2 -> gettext("Tue")
      3 -> gettext("Wed")
      4 -> gettext("Thu")
      5 -> gettext("Fri")
      6 -> gettext("Sat")
      7 -> gettext("Sun")
    end
  end

  def short_date(date), do: Elixir.Calendar.strftime(date, "%d/%m")

  def week_title(monday) do
    gettext("Week of %{from} – %{to}", from: short_date(monday), to: short_date(Date.add(monday, 6)))
  end

  # Competition shown on the card. Racing's and the Selección's own name would
  # repeat the filter, so those cards show the competition they play in.
  # Short names: the card is 1/7 of the page wide on desktop.
  def competition(%{league_id: 112}), do: "Liga Prof."
  def competition(%{league_id: 8965}), do: "Primera Nac."
  def competition(%{league_id: 9305}), do: "Copa Arg."
  def competition(%{league_id: 45}), do: "Libertadores"
  def competition(%{league_id: 299}), do: "Sudamericana"
  def competition(%{league_id: 42}), do: "Champions"
  def competition(%{league_id: 47}), do: "Premier"
  def competition(%{league_name: name}), do: name

  def followed?(id), do: id in Calendar.followed_team_ids()

  def started?(match), do: match.status in [:live, :halftime, :finished]

  # Every line is one line: `truncate` on names and the competition, and the
  # status is a short word kept `whitespace-nowrap`. In a 1/7-width column
  # anything allowed to wrap breaks mid-word.
  attr :match, :map, required: true
  attr :thread, :map, default: nil

  def calendar_card(assigns) do
    ~H"""
    <div class={[
      "relative rounded-lg border bg-surface pl-2.5 pr-2 py-1.5 overflow-hidden",
      if(@match.status in [:live, :halftime], do: "border-danger", else: "border-border")
    ]}>
      <span class={["absolute left-0 inset-y-0 w-1", filter_color(Calendar.filter_key(@match))]}></span>

      <div class="flex items-center gap-1.5 text-[11px] leading-4 min-w-0">
        <.match_status match={@match} />
        <span class="text-muted truncate"><%= competition(@match) %></span>
      </div>

      <div class="mt-1 space-y-0.5 text-[13px] leading-5">
        <.team_row name={@match.home} id={@match.home_id} score={@match.home_score} other={@match.away_score} match={@match} />
        <.team_row name={@match.away} id={@match.away_id} score={@match.away_score} other={@match.home_score} match={@match} />
      </div>

      <.link
        :if={@thread}
        navigate={~p"/t/#{@thread.id}/#{@thread.slug}"}
        class="mt-1 inline-block text-[11px] font-semibold text-accent hover:underline whitespace-nowrap"
      >
        <%= gettext("Go to thread") %> ›
      </.link>
    </div>
    """
  end

  attr :match, :map, required: true

  defp match_status(%{match: %{status: :live}} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 font-bold text-danger whitespace-nowrap flex-shrink-0">
      <span class="w-1.5 h-1.5 rounded-full bg-current animate-pulse"></span>
      <%= @match.minute || gettext("Live") %>
    </span>
    """
  end

  defp match_status(%{match: %{status: :halftime}} = assigns) do
    ~H"""
    <span class="font-bold text-warning whitespace-nowrap flex-shrink-0"><%= gettext("HT") %></span>
    """
  end

  defp match_status(%{match: %{status: :finished}} = assigns) do
    ~H"""
    <span class="font-semibold text-muted whitespace-nowrap flex-shrink-0"><%= gettext("FT") %></span>
    """
  end

  defp match_status(%{match: %{status: :postponed}} = assigns) do
    ~H"""
    <span class="font-semibold text-warning whitespace-nowrap flex-shrink-0"><%= gettext("Postponed") %></span>
    """
  end

  defp match_status(%{match: %{status: :cancelled}} = assigns) do
    ~H"""
    <span class="font-semibold text-warning whitespace-nowrap flex-shrink-0"><%= gettext("Cancelled") %></span>
    """
  end

  defp match_status(assigns) do
    ~H"""
    <span class="font-semibold text-heading tabular-nums whitespace-nowrap flex-shrink-0">
      <%= Calendar.local_time(@match.kickoff) %>
    </span>
    """
  end

  attr :name, :string, required: true
  attr :id, :any, required: true
  attr :score, :any, required: true
  attr :other, :any, required: true
  attr :match, :map, required: true

  defp team_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-1.5 min-w-0">
      <span
        title={@name}
        class={[
          "truncate",
          cond do
            followed?(@id) -> "font-bold text-heading"
            @match.status == :finished and is_integer(@score) and is_integer(@other) and @score < @other -> "text-muted"
            true -> "text-body"
          end
        ]}
      >
        <%= @name %>
      </span>
      <span :if={started?(@match)} class="font-bold tabular-nums text-heading flex-shrink-0"><%= @score %></span>
    </div>
    """
  end
end
