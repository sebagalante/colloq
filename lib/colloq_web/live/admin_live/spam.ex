defmodule ColloqWeb.AdminLive.Spam do
  @moduledoc """
  Spam-classifier dashboard: sidecar status, score distribution, recent
  screenings, and a threshold simulator.

  Built around the one decision shadow mode exists to support — *when is it safe
  to switch to enforce?* — so the histogram and the "what would N flag" control
  are the point of the page, not decoration.
  """
  use ColloqWeb, :live_view

  alias Colloq.{Moderation, SiteSettings, SpamClassifier}

  @window_days 7

  # Polled rather than pushed. Screening happens a handful of times a day on a
  # forum this size, and the page's job is reading a week of history to pick a
  # threshold — not watching events land. The interval mainly earns its keep on
  # the sidecar badge: if the container dies while this is open, it goes red on
  # its own instead of lying until someone reloads.
  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, gettext("Spam classifier"))
     |> assign(:days, @window_days)
     |> assign(:simulated, 0.9)
     |> assign(:word_error, nil)
     |> assign(:sample, "")
     |> assign(:sample_hit, nil)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("simulate", %{"threshold" => value}, socket) do
    threshold =
      case Float.parse(to_string(value)) do
        {f, _} when f >= 0.0 and f <= 1.0 -> f
        _ -> socket.assigns.simulated
      end

    {:noreply,
     socket
     |> assign(:simulated, threshold)
     |> assign(:simulated_count, Moderation.spam_would_flag_at(threshold, socket.assigns.days))}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("add-word", %{"word" => word}, socket) do
    case Moderation.add_blocked_word(word) do
      {:ok, _} ->
        {:noreply, socket |> assign(:words, Moderation.blocked_words()) |> assign(:word_error, nil)}

      {:error, :blank} ->
        {:noreply, assign(socket, :word_error, gettext("Type a word first."))}

      {:error, :duplicate} ->
        {:noreply, assign(socket, :word_error, gettext("That word is already on the list."))}

      {:error, _} ->
        {:noreply, assign(socket, :word_error, gettext("Could not save the list."))}
    end
  end

  def handle_event("remove-word", %{"word" => word}, socket) do
    # The result is checked, not discarded: a failed write used to leave the
    # word on screen with no hint that nothing had been saved.
    error =
      case Moderation.remove_blocked_word(word) do
        {:ok, _} -> nil
        _ -> gettext("Could not save the list.")
      end

    {:noreply,
     socket |> assign(:words, Moderation.blocked_words()) |> assign(:word_error, error)}
  end

  # Lets an admin paste real text and see whether it would be blocked, and by
  # which word — the list is invisible in its effects otherwise.
  def handle_event("test-words", %{"sample" => sample}, socket) do
    {:noreply,
     socket
     |> assign(:sample, sample)
     |> assign(:sample_hit, Moderation.blocked_word_hit(sample))}
  end

  def handle_event("window", %{"days" => days}, socket) do
    days = String.to_integer(days)
    {:noreply, socket |> assign(:days, days) |> load()}
  end

  defp load(socket) do
    days = socket.assigns.days

    socket
    # Included in the poll so a second admin's edits show up here too, rather
    # than each of them working from a stale list.
    |> assign(:words, Moderation.blocked_words())
    |> assign(:health, SpamClassifier.health())
    |> assign(:url, SpamClassifier.url())
    |> assign(:enabled, SiteSettings.get("spam_ml_enabled") == true)
    |> assign(:mode, SiteSettings.get("spam_ml_mode") || "shadow")
    |> assign(:threshold, SiteSettings.get("spam_ml_threshold"))
    |> assign(:stats, Moderation.spam_stats(days))
    |> assign(:histogram, Moderation.spam_score_histogram(days))
    |> assign(:recent, Moderation.recent_spam_classifications(25))
    |> assign(:simulated_count, Moderation.spam_would_flag_at(socket.assigns.simulated, days))
  end

  defp health_label(:ok), do: {"green", gettext("Reachable")}
  defp health_label({:error, :not_configured}), do: {"gray", gettext("Not configured")}
  defp health_label({:error, _}), do: {"red", gettext("Unreachable")}

  # Bar width as a percentage of the tallest bucket, so a quiet week still
  # renders a readable shape instead of ten invisible slivers.
  defp bar_width(_count, 0), do: 0
  defp bar_width(count, max), do: round(count * 100 / max)

  defp pct(score), do: :erlang.float_to_binary(score * 100, decimals: 1)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :max_bucket, Enum.max_by(assigns.histogram, & &1.count).count)

    ~H"""
    <section class="space-y-6">
      <div class="flex items-start justify-between gap-3">
        <div>
          <h1 class="text-2xl font-bold text-heading"><%= gettext("Spam classifier") %></h1>
          <p class="text-sm text-muted mt-1">
            <%= gettext("What the ML sidecar scored, and what a threshold would catch.") %>
          </p>
        </div>
        <button
          type="button"
          phx-click="refresh"
          class="px-3 py-1.5 rounded-md text-sm bg-surface-alt text-body hover:text-heading whitespace-nowrap"
        >
          <%= pgettext("spam", "Refresh") %>
        </button>
      </div>

      <%!-- Status: is it even running? Everything downstream fails open, so a
            dead sidecar looks exactly like "no spam today" without this. --%>
      <.card>
        <div class="flex flex-wrap items-center gap-x-6 gap-y-3">
          <% {color, label} = health_label(@health) %>
          <div class="flex items-center gap-2">
            <span class="text-xs uppercase tracking-wide text-muted"><%= gettext("Sidecar") %></span>
            <.badge color={color}><%= label %></.badge>
          </div>

          <div class="flex items-center gap-2">
            <span class="text-xs uppercase tracking-wide text-muted"><%= gettext("Screening") %></span>
            <.badge color={if @enabled, do: "green", else: "gray"}>
              <%= if @enabled, do: gettext("On"), else: gettext("Off") %>
            </.badge>
          </div>

          <div class="flex items-center gap-2">
            <span class="text-xs uppercase tracking-wide text-muted"><%= pgettext("spam", "Mode") %></span>
            <.badge color={if @mode == "enforce", do: "amber", else: "blue"}><%= @mode %></.badge>
          </div>

          <div :if={@threshold} class="flex items-center gap-2">
            <span class="text-xs uppercase tracking-wide text-muted"><%= gettext("Threshold") %></span>
            <span class="text-sm text-heading tabular-nums"><%= @threshold %></span>
          </div>

          <span :if={@url} class="text-xs text-muted font-mono ml-auto"><%= @url %></span>
        </div>

        <p :if={@enabled and @mode == "shadow"} class="text-xs text-muted mt-3 leading-relaxed">
          <%= gettext(
            "Shadow mode: scores are recorded and nothing is hidden. Read the distribution below, pick a threshold, then switch spam_ml_mode to enforce in Settings."
          ) %>
        </p>
        <p :if={not @enabled} class="text-xs text-muted mt-3 leading-relaxed">
          <%= gettext(
            "Screening is off — set spam_ml_enabled and spam_ml_url in Settings ▸ General. Posts are never blocked while this is off."
          ) %>
        </p>
      </.card>

      <%!-- Window selector + headline counts --%>
      <div class="flex items-center gap-2">
        <span class="text-xs uppercase tracking-wide text-muted"><%= gettext("Window") %></span>
        <button
          :for={d <- [1, 7, 30]}
          type="button"
          phx-click="window"
          phx-value-days={d}
          class={[
            "px-2.5 py-1 rounded-md text-xs",
            @days == d && "bg-accent text-white",
            @days != d && "bg-surface-alt text-muted hover:text-heading"
          ]}
        >
          <%= ngettext("%{count} day", "%{count} days", d, count: d) %>
        </button>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <.card class="!p-3">
          <p class="text-xs text-muted"><%= gettext("Screened") %></p>
          <p class="text-xl font-bold text-heading tabular-nums"><%= @stats.total %></p>
        </.card>
        <.card class="!p-3">
          <p class="text-xs text-muted"><%= gettext("Over threshold") %></p>
          <p class="text-xl font-bold text-heading tabular-nums"><%= @stats.would_flag %></p>
        </.card>
        <.card class="!p-3">
          <p class="text-xs text-muted"><%= gettext("Actually hidden") %></p>
          <p class="text-xl font-bold text-heading tabular-nums"><%= @stats.acted %></p>
        </.card>
        <.card class="!p-3">
          <p class="text-xs text-muted"><%= gettext("Average score") %></p>
          <p class="text-xl font-bold text-heading tabular-nums">
            <%= if @stats.avg_score, do: pct(@stats.avg_score) <> "%", else: "—" %>
          </p>
        </.card>
      </div>

      <%!-- Blocked words: the rule that runs *before* the model, on every
            TL0/TL1 post, and hides outright rather than scoring. --%>
      <.card>
        <h2 class="text-lg font-semibold text-heading mb-1"><%= gettext("Blocked words") %></h2>
        <p class="text-xs text-muted mb-4">
          <%= gettext(
            "Checked before the model, on every post by a new member. A match hides the post immediately — there is no score and no shadow mode here, so keep the list short and specific."
          ) %>
        </p>

        <form phx-submit="add-word" class="flex items-center gap-2 mb-3">
          <input
            type="text"
            name="word"
            value=""
            autocomplete="off"
            placeholder={gettext("Add a word or phrase…")}
            class="flex-1 rounded-lg border border-border bg-surface text-heading px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent"
          />
          <.button type="submit" class="shrink-0"><%= gettext("Add") %></.button>
        </form>

        <p :if={@word_error} class="text-xs text-danger mb-3"><%= @word_error %></p>

        <p :if={@words == []} class="text-sm text-muted">
          <%= gettext("No blocked words. This rule is doing nothing right now.") %>
        </p>

        <div :if={@words != []} class="flex flex-wrap gap-2">
          <span
            :for={w <- @words}
            class="inline-flex items-center gap-1.5 rounded-full bg-surface-alt border border-border pl-3 pr-1.5 py-1 text-sm text-body"
          >
            <%= w %>
            <button
              type="button"
              phx-click="remove-word"
              phx-value-word={w}
              aria-label={gettext("Remove %{word}", word: w)}
              class="text-muted hover:text-danger text-xs px-1"
            >
              ✕
            </button>
          </span>
        </div>

        <%!-- Substring matching means "casino" also hits "casinos" and, less
              happily, "ocasional" — so let an admin check before saving. --%>
        <div class="mt-5 pt-4 border-t border-border">
          <p class="text-xs uppercase tracking-wide text-muted mb-2">
            <%= gettext("Test a text") %>
          </p>
          <form phx-change="test-words">
            <input
              type="text"
              name="sample"
              value={@sample}
              autocomplete="off"
              placeholder={gettext("Paste a post to see if it would be blocked…")}
              class="w-full rounded-lg border border-border bg-surface text-heading px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent"
            />
          </form>
          <p :if={@sample != "" and @sample_hit} class="text-sm text-danger mt-2">
            <%= gettext("Would be blocked by %{word}", word: @sample_hit) %>
          </p>
          <p :if={@sample != "" and is_nil(@sample_hit)} class="text-sm text-success mt-2">
            <%= gettext("Would pass this rule.") %>
          </p>
        </div>
      </.card>

      <%!-- The distribution: the actual reason shadow mode exists. --%>
      <.card>
        <h2 class="text-lg font-semibold text-heading mb-1"><%= gettext("Score distribution") %></h2>
        <p class="text-xs text-muted mb-4">
          <%= gettext(
            "Clean separation — real posts low, spam high — means a threshold is safe. A smear across the middle means enforcing would cost you real posts."
          ) %>
        </p>

        <p :if={@stats.total == 0} class="text-sm text-muted">
          <%= gettext("Nothing screened in this window yet.") %>
        </p>

        <div :if={@stats.total > 0} class="space-y-1.5">
          <div :for={b <- @histogram} class="flex items-center gap-3">
            <span class="text-xs text-muted tabular-nums w-16 shrink-0">
              <%= :erlang.float_to_binary(b.from, decimals: 1) %>–<%= :erlang.float_to_binary(b.to, decimals: 1) %>
            </span>
            <div class="flex-1 h-4 bg-border/40 rounded overflow-hidden">
              <div
                class={["h-full rounded", b.from >= 0.9 && "bg-danger", b.from < 0.9 && "bg-accent"]}
                style={"width: #{bar_width(b.count, @max_bucket)}%"}
              >
              </div>
            </div>
            <span class="text-xs text-muted tabular-nums w-10 text-right shrink-0"><%= b.count %></span>
          </div>
        </div>
      </.card>

      <%!-- Try a threshold against real history before committing to it. --%>
      <.card>
        <h2 class="text-lg font-semibold text-heading mb-1"><%= gettext("Try a threshold") %></h2>
        <p class="text-xs text-muted mb-3">
          <%= gettext("How many of these posts would have been hidden at this cutoff.") %>
        </p>

        <form phx-change="simulate" class="flex items-center gap-4">
          <input
            type="range"
            name="threshold"
            min="0.5"
            max="1"
            step="0.01"
            value={@simulated}
            class="flex-1 accent-accent"
          />
          <span class="text-sm text-heading tabular-nums w-14 text-right"><%= @simulated %></span>
        </form>

        <p class="text-sm text-body mt-3">
          <%= ngettext(
            "%{count} post would be hidden.",
            "%{count} posts would be hidden.",
            @simulated_count,
            count: @simulated_count
          ) %>
          <span class="text-muted">
            <%= gettext("of %{total} screened", total: @stats.total) %>
          </span>
        </p>
      </.card>

      <%!-- Recent rows, highest-scoring first is tempting but chronological is
            what you want when checking "did it just start misfiring?" --%>
      <.card>
        <h2 class="text-lg font-semibold text-heading mb-3"><%= gettext("Recent screenings") %></h2>

        <p :if={@recent == []} class="text-sm text-muted">
          <%= gettext("Nothing screened yet.") %>
        </p>

        <div :if={@recent != []} class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-border">
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("When") %></th>
                <th class="text-left py-2 px-3 text-muted font-medium"><%= gettext("Author") %></th>
                <th class="text-left py-2 px-3 text-muted font-medium"><%= pgettext("spam", "Post") %></th>
                <th class="text-center py-2 px-3 text-muted font-medium"><%= gettext("Score") %></th>
                <th class="text-center py-2 px-3 text-muted font-medium"><%= gettext("Outcome") %></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={c <- @recent} class="border-b border-border/50">
                <td class="py-2 px-3 text-muted whitespace-nowrap tabular-nums">
                  <%= Calendar.strftime(c.inserted_at, "%d/%m %H:%M") %>
                </td>
                <td class="py-2 px-3 text-body">
                  <%= if c.user, do: "@" <> c.user.username, else: "—" %>
                </td>
                <td class="py-2 px-3">
                  <.link
                    :if={c.post}
                    navigate={~p"/t/#{c.post.topic_id}?c=#{c.post_id}"}
                    class="text-accent hover:underline"
                  >
                    <%= if c.post.topic, do: String.slice(c.post.topic.title, 0, 40), else: gettext("View") %>
                  </.link>
                </td>
                <td class={[
                  "py-2 px-3 text-center font-bold tabular-nums",
                  c.would_flag && "text-danger",
                  !c.would_flag && "text-muted"
                ]}>
                  <%= pct(c.score) %>%
                </td>
                <td class="py-2 px-3 text-center">
                  <.badge :if={c.acted} color="red"><%= pgettext("spam", "Hidden") %></.badge>
                  <.badge :if={c.would_flag and not c.acted} color="amber">
                    <%= gettext("Would flag") %>
                  </.badge>
                  <span :if={not c.would_flag} class="text-muted text-xs"><%= pgettext("spam", "Allowed") %></span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </section>
    """
  end
end
