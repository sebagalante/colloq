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

  # Emoji palette shown in the reaction picker popup.
  @reaction_emojis ~w(👍 ❤️ 😂 😮 😢 🔥 🎉 💯 👏 🙌 🤝 🚀 🤩 👀 ⚽ 🏆)

  def reaction_bar(assigns) do
    assigns =
      assigns
      |> assign(:reaction_emojis, @reaction_emojis)
      |> assign(:custom_emojis, Colloq.Emojis.map())

    ~H"""
    <div class="flex items-center flex-wrap gap-1.5">
      <%!-- Existing reactions (only those with at least one) --%>
      <button
        :for={%{emoji: emoji, count: count} <- Enum.filter(@reactions, &(&1.count > 0))}
        type="button"
        phx-click="reaction"
        phx-value-post_id={@post_id}
        phx-value-emoji={emoji}
        class={[
          "reaction-pill flex items-center gap-1 rounded-full px-2.5 py-1 text-xs transition-colors",
          @user_reactions && MapSet.member?(@user_reactions, emoji) &&
            "bg-accent-soft border border-accent text-accent",
          (!@user_reactions || !MapSet.member?(@user_reactions, emoji)) &&
            "bg-border border border-transparent hover:bg-border-hover text-muted"
        ]}
      >
        <span><%= emoji_display(emoji, @custom_emojis) %></span>
        <span class="tabular-nums"><%= count %></span>
      </button>

      <%!-- Add-reaction button + emoji picker popup --%>
      <div class="relative">
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
end
