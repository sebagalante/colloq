defmodule ColloqWeb.Components.Prode do
  @moduledoc """
  Shared prode (predictions) UI bits.

  The scoring explainer reads its numbers from `Colloq.Predictions.Scorer.weights/0`
  rather than hardcoding them, so changing a point value in the scorer updates
  what players are told — the two can't drift apart.
  """
  use Phoenix.Component

  import ColloqWeb.Gettext
  import ColloqWeb.Components.Lucide, only: [icon: 1]

  alias Colloq.Predictions.Scorer

  @doc """
  Collapsible "how scoring works" panel.

  Rendered closed by default: on the predictions page it sits above the round
  form, where an always-open block would push the matches below the fold.
  """
  attr :open, :boolean, default: false, doc: "start expanded"
  attr :class, :string, default: nil

  def scoring_rules(assigns) do
    assigns = assign(assigns, :w, Scorer.weights())

    ~H"""
    <details
      open={@open}
      class={["rounded-xl border border-border bg-surface overflow-hidden group", @class]}
    >
      <summary class="flex items-center gap-2 px-5 py-3 cursor-pointer select-none text-sm font-medium text-heading hover:bg-surface-alt transition-colors">
        <.icon name="help-circle" class="w-4 h-4 text-accent" />
        <%= pgettext("prode", "How does scoring work?") %>
        <.icon
          name="chevron-down"
          class="w-4 h-4 text-muted ml-auto group-open:rotate-180 transition-transform"
        />
      </summary>

      <div class="px-5 pb-5 pt-1 space-y-4">
        <p class="text-sm text-muted leading-relaxed">
          <%= pgettext(
            "prode",
            "Every match is scored on its own, and only one tier applies — the best one your prediction reaches."
          ) %>
        </p>

        <div>
          <h3 class="text-xs font-semibold uppercase tracking-wide text-muted mb-2">
            <%= pgettext("prode", "The result") %>
          </h3>
          <div class="overflow-x-auto">
            <table class="w-full text-sm">
              <tbody>
                <.rule_row points={@w.exact} label={pgettext("prode", "Exact score")} example="2-0 → 2-0" />
                <.rule_row
                  points={@w.close}
                  label={pgettext("prode", "Right winner, and both scores off by at most one goal")}
                  example="1-0 → 2-0"
                />
                <.rule_row
                  points={@w.outcome}
                  label={pgettext("prode", "Right winner (or draw), any score")}
                  example="5-0 → 2-0"
                />
                <.rule_row points={0} label={pgettext("prode", "Wrong winner")} example="0-1 → 2-0" />
              </tbody>
            </table>
          </div>
          <p class="text-xs text-muted mt-2 leading-relaxed">
            <%= pgettext(
              "prode",
              "Each side is checked on its own, not the goal difference: on a 2-0, guessing 1-0 scores %{close} but 3-1 scores %{outcome}.",
              close: @w.close,
              outcome: @w.outcome
            ) %>
          </p>
        </div>

        <%!-- `Scorer` also awards first-scorer and man-of-the-match bonuses, but
              the round form collects neither (`collect_entries/2` builds only
              scores), so documenting them would promise points nobody can earn.
              Restore this section when those inputs ship. --%>
        <p class="text-sm text-body">
          <%= pgettext("prode", "Best possible match: %{max} points.", max: @w.exact) %>
        </p>

        <p class="text-xs text-muted leading-relaxed">
          <%= pgettext(
            "prode",
            "Predictions close at kickoff and are scored once the match finishes — it can take a few minutes. The standings add up every point of the season; players whose guesses all missed stay on the table with 0."
          ) %>
        </p>
      </div>
    </details>
    """
  end

  attr :points, :integer, required: true
  attr :label, :string, required: true
  attr :example, :string, default: nil
  attr :sign, :boolean, default: false, doc: "render as +N (a bonus) rather than N"

  defp rule_row(assigns) do
    ~H"""
    <tr class="border-b border-border/50 last:border-0">
      <td class="py-1.5 pr-3 w-12 text-heading font-bold tabular-nums whitespace-nowrap">
        <%= if @sign, do: "+#{@points}", else: @points %>
      </td>
      <td class="py-1.5 pr-3 text-body"><%= @label %></td>
      <td :if={@example} class="py-1.5 text-right text-xs text-muted tabular-nums whitespace-nowrap">
        <%= @example %>
      </td>
    </tr>
    """
  end
end
