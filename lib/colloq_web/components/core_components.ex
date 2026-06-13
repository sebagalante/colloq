defmodule ColloqWeb.CoreComponents do
  @moduledoc """
  Shared UI components for Colloq.
  """
  use ColloqWeb, :html

  alias Phoenix.LiveView.JS

  # ============= FLASH =============
  attr :kind, :atom, required: true, values: [:info, :error]
  attr :rest, :global
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <div
      role="alert"
      class={[
        "rounded-lg px-4 py-3 text-sm mb-4",
        @kind == :info && "bg-blue-900/30 border border-blue-700 text-blue-300",
        @kind == :error && "bg-red-900/30 border border-red-700 text-red-300"
      ]}
      {@rest}
    >
      <button :if={@rest[:on_click]} phx-click={@rest[:on_click]} class="float-right text-xs opacity-60 hover:opacity-100">
        ✕
      </button>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} rest={%{on_click: JS.push("lv:clear-flash") |> JS.remove_class("show")}}>
      <%= live_flash(@flash, :info) %>
    </.flash>
    <.flash kind={:error} rest={%{on_click: JS.push("lv:clear-flash") |> JS.remove_class("show")}}>
      <%= live_flash(@flash, :error) %>
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
        "bg-blue-600 hover:bg-blue-500 text-white transition-colors",
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
  attr :id, :any
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(placeholder required disabled)

  def input(assigns) do
    ~H"""
    <div class="mb-4">
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-300 mb-1">
        <%= @label %>
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "w-full rounded-lg border bg-[#0f1420] text-white px-3 py-2 text-sm",
          "focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500",
          @errors != [] && "border-red-500 focus:border-red-500 focus:ring-red-500",
          @errors == [] && "border-[#1a2035]"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}><%= msg %></.error>
    </div>
    """
  end

  # ============= TEXTAREA =============
  attr :id, :any
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :errors, :list, default: []
  attr :rest, :global

  def textarea(assigns) do
    ~H"""
    <div class="mb-4">
      <label :if={@label} for={@id} class="block text-sm font-medium text-gray-300 mb-1">
        <%= @label %>
      </label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "w-full rounded-lg border bg-[#0f1420] text-white px-3 py-2 text-sm min-h-[100px]",
          "focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500",
          @errors != [] && "border-red-500",
          @errors == [] && "border-[#1a2035]"
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
    <div class={["bg-[#0f1420] border border-[#1a2035] rounded-xl p-5", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  # ============= BADGE =============
  attr :color, :string, default: "blue"
  slot :inner_block, required: true

  def badge(assigns) do
    colors = %{
      "blue" => "bg-blue-900/30 text-blue-300 border-blue-700",
      "green" => "bg-green-900/30 text-green-300 border-green-700",
      "red" => "bg-red-900/30 text-red-300 border-red-700",
      "amber" => "bg-amber-900/30 text-amber-300 border-amber-700",
      "purple" => "bg-purple-900/30 text-purple-300 border-purple-700",
      "gray" => "bg-gray-800 text-gray-400 border-gray-700"
    }

    ~H"""
    <span class={["inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium border", colors[@color]]}>
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
    <div id={@id} phx-mounted={@show && JS.show(transition: "fade-in")} phx-remove={JS.hide(transition: "fade-out")} class="hidden">
      <div class="fixed inset-0 z-50 bg-black/60" phx-click={@on_cancel}></div>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="bg-[#0f1420] border border-[#1a2035] rounded-xl max-w-lg w-full p-6 shadow-2xl">
          <div :if={@title != []} class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-semibold text-white"><%= render_slot(@title) %></h3>
            <button phx-click={@on_cancel} class="text-gray-500 hover:text-white transition-colors">✕</button>
          </div>
          <%= render_slot(@inner_block) %>
        </div>
      </div>
    </div>
    """
  end

  # ============= REACTION BAR (placeholder for v9) =============
  attr :post_id, :integer, required: true
  attr :reactions, :list, default: []

  def reaction_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mt-3">
      <button class="flex items-center gap-1 rounded-full bg-[#1a2035] px-2.5 py-1 text-xs hover:bg-[#253048] transition-colors group">
        <span class="grayscale group-hover:grayscale-0 transition-all">❤️</span>
        <span class="text-gray-400">12</span>
      </button>
      <!-- More reactions rendered dynamically from @reactions -->
    </div>
    """
  end

  # ============= MATCH SCORE PIN (placeholder for match day) =============
  attr :home_team, :string, required: true
  attr :away_team, :string, required: true
  attr :home_score, :integer, default: 0
  attr :away_score, :integer, default: 0
  attr :minute, :integer, default: 0

  def match_score_pin(assigns) do
    ~H"""
    <div class="sticky top-0 z-40 bg-[#0f1420] border-b border-[#1a2035] px-4 py-3 flex items-center justify-between">
      <div class="flex items-center gap-4">
        <span class="text-sm font-bold text-white"><%= @home_team %></span>
        <span class="text-2xl font-bold text-white tabular-nums">
          <%= @home_score %> - <%= @away_score %>
        </span>
        <span class="text-sm font-bold text-white"><%= @away_team %></span>
      </div>
      <span class="text-sm font-mono text-green-400"><%= @minute %>'</span>
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
