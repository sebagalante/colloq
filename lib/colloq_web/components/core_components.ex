defmodule ColloqWeb.CoreComponents do
  @moduledoc """
  Shared UI components for Colloq.
  """
  use Phoenix.Component

  import ColloqWeb.Components.Lucide, only: [icon: 1]
  import ColloqWeb.Gettext

  alias Phoenix.LiveView.JS

  # ============= FLASH =============
  attr :kind, :atom, required: true, values: [:info, :error]
  attr :on_click, JS, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <div
      role="alert"
      class={[
        "rounded-lg px-4 py-3 text-sm mb-4",
        @kind == :info && "bg-accent-soft border border-accent-border text-accent",
        @kind == :error && "bg-danger-soft border border-danger-border text-danger"
      ]}
      {@rest}
    >
      <button :if={@on_click} phx-click={@on_click} class="float-right text-xs opacity-60 hover:opacity-100">
        ✕
      </button>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <.flash
      :if={msg = Phoenix.Flash.get(@flash, :info)}
      id="flash-info"
      kind={:info}
      phx-hook="FlashAutoHide"
      data-auto-hide="10000"
      on_click={JS.push("lv:clear-flash", value: %{key: "info"})}
    >
      <%= msg %>
    </.flash>
    <.flash
      :if={msg = Phoenix.Flash.get(@flash, :error)}
      id="flash-error"
      kind={:error}
      phx-hook="FlashAutoHide"
      data-auto-hide="10000"
      on_click={JS.push("lv:clear-flash", value: %{key: "error"})}
    >
      <%= msg %>
    </.flash>
    """
  end

  # ============= BUTTON =============
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center rounded-lg px-4 py-2 text-sm font-semibold",
        "bg-accent hover:bg-accent-hover text-white transition-colors",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  # ============= INPUT =============
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(placeholder required disabled min max step pattern autocomplete inputmode)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    # Force the field's id/name/value (attrs carry a default of nil, so assign_new
    # would be a no-op and the typed value would be wiped on every re-render).
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, field.name)
    |> assign(:value, field.value)
    |> assign(:errors, if(assigns.errors != [], do: assigns.errors, else: Enum.map(field.errors, fn {msg, _opts} -> msg end)))
    |> input()
  end

  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label :if={@label} for={@id} class="block text-sm font-medium text-muted mb-1">
        <%= @label %>
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "w-full rounded-lg border bg-surface text-heading px-3 py-2 text-sm",
          "focus:outline-none focus:ring-2 focus:ring-accent focus:border-accent",
          @errors != [] && "border-danger focus:border-danger focus:ring-danger",
          @errors == [] && "border-border"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  # ============= TEXTAREA =============
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(placeholder required disabled rows)

  def textarea(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, field.name)
    |> assign(:value, field.value)
    |> assign(:errors, if(assigns.errors != [], do: assigns.errors, else: Enum.map(field.errors, fn {msg, _opts} -> msg end)))
    |> textarea()
  end

  def textarea(assigns) do
    ~H"""
    <div class="mb-4">
      <label :if={@label} for={@id} class="block text-sm font-medium text-muted mb-1">
        <%= @label %>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "w-full rounded-lg border bg-surface text-heading px-3 py-2 text-sm min-h-[100px]",
          "focus:outline-none focus:ring-2 focus:ring-accent focus:border-accent",
          @errors != [] && "border-danger",
          @errors == [] && "border-border"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  # ============= ERROR =============
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-1 text-xs text-red-400">
      <span class="mr-1">⚠</span><%= render_slot(@inner_block) %>
    </p>
    """
  end

  # ============= CARD =============
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["bg-surface border border-border rounded-xl p-5", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ============= BADGE =============
  attr :color, :string, default: "blue"
  slot :inner_block, required: true

  def badge(assigns) do
    colors = %{
      "blue" => "bg-accent-soft text-accent border-accent-border",
      "green" => "bg-success-soft text-success border-success/50",
      "red" => "bg-danger-soft text-danger border-danger/50",
      "amber" => "bg-warning-soft text-warning border-warning/50",
      "purple" => "bg-purple-900/30 text-purple-300 border-purple-700",
      "gray" => "bg-surface-alt text-muted border-border"
    }

    hex_color = if @color && String.starts_with?(@color, "#"), do: @color

    assigns =
      assigns
      |> assign(:named_class, colors[@color])
      |> assign(:hex_color, hex_color)

    ~H"""
    <span
      :if={@named_class}
      class={["inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium border", @named_class]}
    >
      <%= render_slot(@inner_block) %>
    </span>
    <span
      :if={!@named_class && @hex_color}
      class="inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium border"
      style={"background-color: #{@hex_color}20; color: #{@hex_color}; border-color: #{@hex_color}60"}
    >
      <%= render_slot(@inner_block) %>
    </span>
    <span
      :if={!@named_class && !@hex_color}
      class={["inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium border", colors["blue"]]}
    >
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  # ============= STAFF BADGE =============
  # Staff badge, colored and glyphed by role:
  #   super admin → two Corinthian (plumed) helmets, gray
  #   admin       → one Corinthian helmet, blue
  #   moderator   → hard hat, green
  # Regular users render nothing.
  attr :role, :string, default: nil
  attr :show_label, :boolean, default: true
  attr :class, :string, default: nil

  def staff_badge(assigns) do
    cfg = Colloq.Permissions.staff_badge(assigns.role)

    colors = %{
      "gray" => "bg-surface-alt text-muted border-border",
      "blue" => "bg-accent-soft text-accent border-accent-border",
      "green" => "bg-success-soft text-success border-success/50"
    }

    assigns =
      assigns
      |> assign(:cfg, cfg)
      |> assign(:color_class, cfg && colors[cfg.color])

    ~H"""
    <span
      :if={@cfg}
      class={[
        "inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-xs font-medium",
        @color_class,
        @class
      ]}
      title={@cfg.label}
    >
      <span class="inline-flex items-center gap-0.5">
        <.staff_glyph :for={_ <- 1..@cfg.count//1} icon={@cfg.icon} class="w-3.5 h-3.5" />
      </span>
      <span :if={@show_label}><%= @cfg.label %></span>
    </span>
    """
  end

  attr :icon, :atom, required: true
  attr :class, :string, default: "w-4 h-4"

  @doc "Dispatches to the right staff glyph (`:helmet` or `:hardhat`)."
  def staff_glyph(assigns) do
    ~H"""
    <.corinthian_helmet :if={@icon == :helmet} class={@class} />
    <.hard_hat :if={@icon == :hardhat} class={@class} />
    """
  end

  attr :class, :string, default: "w-4 h-4"

  @doc "Corinthian (Greek) plumed-helmet glyph."
  def corinthian_helmet(assigns) do
    ~H"""
    <svg viewBox="0 0 512 512" fill="currentColor" class={@class} aria-hidden="true">
      <path d="m207.47 18.875 35.968 162.25c.29 1.087.86 1.863 2.562 2.813 1.7.95 4.433 1.66 7.22 1.656 2.785-.003 5.543-.703 7.25-1.656 1.704-.954 2.276-1.75 2.56-2.813L299 18.875h-91.53zm88.936 98.03-15.22 68.657-.06.22-.032.187c-1.747 6.52-6.404 11.432-11.5 14.28-5.096 2.848-10.738 4.026-16.344 4.03-5.606.007-11.24-1.15-16.344-4-5.104-2.847-9.782-7.784-11.53-14.31l-.032-.19-.063-.218-14.686-66.218C175 133.818 147.157 164.56 135.53 202.97a458.472 458.472 0 0 0 32.314 15.468c26.527 11.43 60.506 22.55 88.5 22.406 28.003-.145 61.81-11.56 88.156-23.22a448.74 448.74 0 0 0 32.938-16.25c-12.624-39.968-42.853-71.398-81.032-84.468zm88.97 101.376c-8.365 4.538-19.865 10.487-33.313 16.44-27.522 12.18-62.797 24.673-95.625 24.843-32.838.17-68.293-12-96-23.938-13.614-5.866-25.276-11.744-33.72-16.22-.51 70.485-3.647 138.64 9.626 188.376 7.135 26.737 18.683 47.874 37.375 62.595 12.092 9.525 27.443 16.584 47.25 20.375V330.125c-28.654 16.12-67.847 2.81-81.064-30.625 8.825-22.322 30.127-33.074 50.78-33 24.583.087 48.224 15.532 48.876 45.094h.094v89h36.03l.002-87.72c-.01-.01-.023-.018-.032-.03 0-.422.022-.834.03-1.25.655-29.562 24.327-45.007 48.908-45.094 20.654-.074 41.926 10.678 50.75 33-13.204 33.403-52.324 46.702-80.97 30.656v160.47c19.544-3.867 34.6-11 46.438-20.595 18.396-14.908 29.6-36.337 36.375-63.342 12.59-50.184 8.804-118.532 8.188-188.407z" />
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  @doc "Hard-hat glyph (Lucide) marking moderators."
  def hard_hat(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      <path d="M2 18a1 1 0 0 0 1 1h18a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v2z" />
      <path d="M10 10V5a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v5" />
      <path d="M4 15v-3a6 6 0 0 1 6-6" />
      <path d="M14 6a6 6 0 0 1 6 6v3" />
    </svg>
    """
  end

  # ============= MODAL =============
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true
  slot :title

  def modal(assigns) do
    ~H"""
    <div :if={@show} id={@id} class="relative z-50">
      <div class="fixed inset-0 z-40 bg-black/60" phx-click={@on_cancel}></div>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto">
        <div class="bg-surface border border-border rounded-xl max-w-lg w-full p-6 shadow-2xl my-8">
          <div :if={@title != []} class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-semibold text-heading"><%= render_slot(@title) %></h3>
            <button phx-click={@on_cancel} class="text-muted hover:text-heading transition-colors">✕</button>
          </div>
          <%= render_slot(@inner_block) %>
        </div>
      </div>
    </div>
    """
  end

  # ============= REACTION BAR =============
  attr :post_id, :integer, required: true
  attr :reactions, :list, default: []
  attr :user_reactions, :map, default: nil

  attr :can_react, :boolean,
    default: true,
    doc: "false on the viewer's own posts — counts still render, but not the controls"

  # Emoji palette shown in the reaction picker popup.
  @reaction_emojis ~w(👍 💙 😂 😮 😢 🔥 🎉 💯 👏 🙌 🤝 🚀 🤩 👀 ⚽ 🏆)

  def reaction_bar(assigns) do
    assigns =
      assigns
      |> assign(:reaction_emojis, @reaction_emojis)
      |> assign(:custom_emojis, Colloq.Emojis.map())

    ~H"""
    <div class="flex items-center flex-wrap gap-1.5">
      <%!-- Existing reactions (only those with at least one) --%>
      <%!-- On your own posts the pills are inert: you can see who reacted, but
            clicking would be rejected server-side anyway. --%>
      <button
        :for={%{emoji: emoji, count: count} <- Enum.filter(@reactions, &(&1.count > 0))}
        type="button"
        disabled={!@can_react}
        phx-click={@can_react && "reaction"}
        phx-value-post_id={@post_id}
        phx-value-emoji={emoji}
        class={[
          "reaction-pill flex items-center gap-1 rounded-full px-2.5 py-1 text-xs transition-colors",
          !@can_react && "cursor-default",
          @user_reactions && MapSet.member?(@user_reactions, emoji) &&
            "bg-accent-soft border border-accent text-accent",
          (!@user_reactions || !MapSet.member?(@user_reactions, emoji)) &&
            "bg-border border border-transparent text-muted",
          @can_react && (!@user_reactions || !MapSet.member?(@user_reactions, emoji)) &&
            "hover:bg-border-hover"
        ]}
      >
        <span><%= emoji_display(emoji, @custom_emojis) %></span>
        <span class="tabular-nums"><%= count %></span>
      </button>

      <%!-- Add-reaction button + emoji picker popup --%>
      <div :if={@can_react} class="relative">
        <button
          type="button"
          phx-click={JS.toggle(to: "#emoji-picker-#{@post_id}")}
          class="flex items-center justify-center w-7 h-7 rounded-full bg-border border border-transparent hover:bg-border-hover text-muted hover:text-heading transition-colors"
          title={gettext("Add reaction")}
        >
          <.icon name="thumbs-up" class="w-4 h-4" />
        </button>

        <div
          id={"emoji-picker-#{@post_id}"}
          class="hidden absolute z-50 bottom-full mb-2 left-0 p-2 rounded-xl bg-surface border border-border shadow-lg"
          phx-click-away={JS.hide(to: "#emoji-picker-#{@post_id}")}
        >
          <div class="grid grid-cols-8 gap-0.5 w-max">
            <button
              :for={emoji <- @reaction_emojis}
              type="button"
              phx-click={
                JS.hide(to: "#emoji-picker-#{@post_id}")
                |> JS.push("reaction", value: %{post_id: to_string(@post_id), emoji: emoji})
              }
              class="emoji-choice text-xl leading-none p-1.5 rounded-lg hover:bg-surface-alt transition-colors"
            >
              <%= emoji %>
            </button>
          </div>

          <%!-- Custom emoji --%>
          <div :if={@custom_emojis != %{}} class="mt-1 pt-1 border-t border-border grid grid-cols-8 gap-0.5 w-max">
            <button
              :for={{name, url} <- @custom_emojis}
              type="button"
              title={":#{name}:"}
              phx-click={
                JS.hide(to: "#emoji-picker-#{@post_id}")
                |> JS.push("reaction", value: %{post_id: to_string(@post_id), emoji: ":#{name}:"})
              }
              class="p-1.5 rounded-lg hover:bg-surface-alt transition-colors"
            >
              <img src={url} alt={":#{name}:"} class="w-5 h-5 object-contain" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Render a reaction "emoji" value: a custom-emoji image for a known
  # ":name:" shortcode, otherwise the raw unicode emoji.
  defp emoji_display(emoji, custom_emojis) do
    case Colloq.Emojis.shortcode_img(emoji, custom_emojis) do
      nil -> emoji
      html -> Phoenix.HTML.raw(html)
    end
  end

  # ============= MATCH SCORE PIN (placeholder for match day) =============
  attr :home_team, :string, required: true
  attr :away_team, :string, required: true
  attr :home_score, :integer, default: 0
  attr :away_score, :integer, default: 0
  attr :minute, :integer, default: 0

  def match_score_pin(assigns) do
    ~H"""
    <div class="sticky top-0 z-40 bg-surface border-b border-border px-4 py-3 flex items-center justify-between">
      <div class="flex items-center gap-4">
        <span class="text-sm font-bold text-heading"><%= @home_team %></span>
        <span class="text-2xl font-bold text-heading tabular-nums">
          <%= @home_score %> - <%= @away_score %>
        </span>
        <span class="text-sm font-bold text-heading"><%= @away_team %></span>
      </div>
      <span class="text-sm font-mono text-success"><%= @minute %>'</span>
    </div>
    """
  end

  # ============= GOAL ALERT =============
  attr :player, :string, required: true
  attr :minute, :integer, required: true

  def goal_alert(assigns) do
    ~H"""
    <div class="fixed top-20 left-1/2 -translate-x-1/2 z-50 bg-green-900/90 border border-green-600 text-green-100 px-6 py-3 rounded-xl shadow-lg animate-bounce">
      ⚽ ¡GOOOL! <%= @player %> <%= @minute %>'
    </div>
    """
  end

  # ============= LINEUP JERSEY =============
  # A little football shirt drawn in the team's kit colors, used for both the
  # lineup composer preview and the posted lineup board. GK gets a fixed
  # contrasting yellow so the keeper stands out from the outfield players.
  attr :primary, :string, default: "#e8eef7"
  attr :secondary, :string, default: "#9db4d0"
  attr :gk, :boolean, default: false
  attr :class, :any, default: "w-7 h-6"

  def jersey(assigns) do
    ~H"""
    <svg viewBox="0 0 60 56" class={@class} aria-hidden="true">
      <path
        d="M18 4 L24 8 Q30 12 36 8 L42 4 L54 12 L48 22 L44 20 L44 52 L16 52 L16 20 L12 22 L6 12 Z"
        fill={if @gk, do: "#facc15", else: @primary}
        stroke={if @gk, do: "#a16207", else: @secondary}
        stroke-width="1.6"
      />
    </svg>
    """
  end

  # ============= STANDINGS TABLE (SVG) =============
  # Renders a Sofascore-style league table as an inline SVG stored in the system
  # post's event_data. We render it raw (not through the body sanitizer, which
  # strips SVG) — the markup is generated by us in Colloq.Sofascore.StandingsSvg
  # and every external value inside it is XML-escaped there.
  attr :data, :map, required: true

  def standings_table(assigns) do
    assigns = assign(assigns, :svg, assigns.data["svg"] || assigns.data[:svg])

    ~H"""
    <div :if={@svg} class="not-prose my-2 overflow-x-auto rounded-xl">
      <%= Phoenix.HTML.raw(@svg) %>
    </div>
    """
  end
end
