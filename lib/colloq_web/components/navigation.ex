defmodule ColloqWeb.Components.Navigation do
  @moduledoc """
  Global app chrome: top header and left sidebar (Discourse-style).

  Rendered from the `:app` layout, so it appears on every LiveView. Relies on
  `@current_user` and `@categories` being assigned by `ColloqWeb.UserAuth.on_mount/4`.
  """
  use ColloqWeb, :html

  alias Colloq.Permissions

  @doc false
  def top_level_categories(categories) do
    Enum.filter(categories, &is_nil(&1.parent_id))
  end

  @doc false
  def child_categories(categories, parent_id) do
    Enum.filter(categories, &(&1.parent_id == parent_id))
  end

  attr :current_user, :any, default: nil
  attr :unread_notifications, :integer, default: 0
  attr :unread_messages, :integer, default: 0
  attr :search_query, :string, default: ""

  @doc "Top header bar: logo, search, notifications, and the user / auth menu."
  def app_header(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 bg-surface border-b border-border">
      <div class="mx-auto max-w-7xl px-4 h-14 flex items-center gap-4">
        <button
          type="button"
          class="md:hidden text-muted hover:text-heading"
          phx-click={JS.toggle(to: "#app-sidebar")}
          aria-label={gettext("Toggle menu")}
        >
          <.icon name="menu" class="w-6 h-6" />
        </button>

        <.link navigate={~p"/"} class="flex items-center gap-2 font-bold text-heading text-lg">
          <span class="text-accent">◆</span> Colloq
        </.link>

        <form action={~p"/search"} method="get" class="hidden sm:flex flex-1 max-w-md">
          <div class="flex items-center gap-2 w-full rounded-lg bg-surface-alt border border-border px-3 py-1.5 focus-within:border-accent focus-within:ring-2 focus-within:ring-accent transition-colors">
            <.icon name="search" class="w-4 h-4 text-muted flex-shrink-0" />
            <input
              type="text"
              name="q"
              value={@search_query}
              autocomplete="off"
              placeholder={gettext("Search…")}
              class="flex-1 bg-transparent text-sm text-heading placeholder:text-muted focus:outline-none"
            />
          </div>
        </form>

        <div class="flex items-center gap-2 ml-auto">
          <.link
            navigate={~p"/search"}
            class="sm:hidden p-2 rounded-lg text-muted hover:text-heading hover:bg-surface-alt transition-colors"
            title={gettext("Search")}
          >
            <.icon name="search" class="w-5 h-5" />
          </.link>
          <%= if @current_user do %>
            <.link
              navigate={~p"/notifications"}
              class="relative p-2 rounded-lg text-muted hover:text-heading hover:bg-surface-alt transition-colors"
              title={gettext("Notifications")}
            >
              <.icon name="bell" class="w-5 h-5" />
              <span
                :if={@unread_notifications > 0}
                class="absolute top-0.5 right-0.5 min-w-[16px] h-4 px-1 rounded-full bg-danger text-white text-[10px] font-bold flex items-center justify-center"
              >
                <%= min(@unread_notifications, 99) %>
              </span>
            </.link>
            <.link
              navigate={~p"/messages"}
              class="relative p-2 rounded-lg text-muted hover:text-heading hover:bg-surface-alt transition-colors"
              title={gettext("Messages")}
            >
              <.icon name="mail" class="w-5 h-5" />
              <span
                :if={@unread_messages > 0}
                class="absolute top-0.5 right-0.5 min-w-[16px] h-4 px-1 rounded-full bg-danger text-white text-[10px] font-bold flex items-center justify-center"
              >
                <%= min(@unread_messages, 99) %>
              </span>
            </.link>

            <div class="relative">
              <button
                type="button"
                phx-click={JS.toggle(to: "#user-menu")}
                class="flex items-center gap-2 p-1 rounded-lg hover:bg-surface-alt transition-colors"
              >
                <.user_avatar user={@current_user} class="w-8 h-8" />
              </button>

              <div
                id="user-menu"
                class="hidden absolute right-0 mt-2 w-52 rounded-lg bg-surface border border-border shadow-lg py-1 z-50"
                phx-click-away={JS.hide()}
              >
                <div class="px-3 py-2 border-b border-border">
                  <p class="text-sm font-semibold text-heading truncate">{@current_user.username}</p>
                  <p class="text-xs text-muted truncate">{@current_user.email}</p>
                </div>
                <.menu_link navigate={~p"/u/#{@current_user.username}"} icon="user" label={gettext("Profile")} />
                <.menu_link navigate={~p"/messages"} icon="mail" label={gettext("Messages")} />
                <.menu_link navigate={~p"/bookmarks"} icon="bookmark" label={gettext("Bookmarks")} />
                <.menu_link navigate={~p"/settings"} icon="settings" label={gettext("Settings")} />
                <.menu_link
                  :if={Permissions.can_any?(@current_user, [:view_dashboard, :view_users])}
                  navigate={~p"/admin"}
                  icon="bar-chart-3"
                  label={gettext("Admin")}
                />
                <div class="border-t border-border my-1"></div>
                <a
                  href={~p"/logout"}
                  class="flex items-center gap-2 px-3 py-2 text-sm text-muted hover:text-heading hover:bg-surface-alt"
                >
                  <.icon name="log-out" class="w-4 h-4" />
                  {gettext("Log out")}
                </a>
              </div>
            </div>
          <% else %>
            <.link
              navigate={~p"/login"}
              class="px-3 py-1.5 rounded-lg text-sm font-medium text-muted hover:text-heading transition-colors"
            >
              {gettext("Log in")}
            </.link>
            <.link
              navigate={~p"/register"}
              class="px-3 py-1.5 rounded-lg text-sm font-semibold bg-accent hover:bg-accent-hover text-white transition-colors"
            >
              {gettext("Sign up")}
            </.link>
          <% end %>
        </div>
      </div>
    </header>
    """
  end

  attr :current_user, :any, default: nil
  attr :categories, :list, default: []
  attr :sidebar_tags, :list, default: []

  @doc "Left sidebar: primary links, category list and public tag list."
  def sidebar(assigns) do
    ~H"""
    <aside
      id="app-sidebar"
      class="hidden md:block w-60 flex-shrink-0 border-r border-border px-3 py-4 overflow-y-auto scrollbar-none"
    >
      <nav class="space-y-6">
        <div class="space-y-1">
          <.nav_link navigate={~p"/"} icon="home" label={gettext("Forum")} />
          <.nav_link navigate={~p"/predicciones"} icon="trending-up" label={gettext("Predictions")} />
          <.nav_link :if={@current_user} navigate={~p"/bookmarks"} icon="bookmark" label={gettext("Bookmarks")} />

          <%!-- More (expandable) --%>
          <div>
            <button
              type="button"
              phx-click={
                JS.toggle(to: "#sidebar-more")
                |> JS.toggle_class("rotate-90", to: "#sidebar-more-chevron")
              }
              class="flex items-center gap-3 w-full px-3 py-1.5 rounded-lg text-sm font-medium text-muted hover:text-heading hover:bg-surface-alt transition-colors"
            >
              <.icon name="more-horizontal" class="w-4 h-4" />
              {gettext("More")}
              <span id="sidebar-more-chevron" class="ml-auto text-xs transition-transform">▸</span>
            </button>
            <div id="sidebar-more" class="hidden mt-1 space-y-1">
              <.nav_link navigate={~p"/members"} icon="users" label={gettext("Members")} />
              <.nav_link navigate={~p"/leaderboard"} icon="award" label={gettext("Leaderboard")} />
              <.nav_link navigate={~p"/badges"} icon="star" label={gettext("Badges")} />
              <.nav_link navigate={~p"/about"} icon="info" label={gettext("About")} />
              <.nav_link navigate={~p"/guidelines"} icon="file-text" label={gettext("Guidelines")} />
            </div>
          </div>
        </div>

        <div :if={@categories != []}>
          <h3 class="px-3 mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
            {gettext("Categories")}
          </h3>
          <div id="category-tree" phx-hook="CategoryTree" class="space-y-1">
            <div :for={cat <- top_level_categories(@categories)}>
              <% children = child_categories(@categories, cat.id) %>
              <%!-- The category name stays a link; the chevron is a separate
                    control, so opening the list never costs you the ability to
                    click through to the parent. --%>
              <div class="flex items-center gap-1">
                <.link
                  navigate={~p"/c/#{cat.slug}"}
                  title={cat.name}
                  class="flex-1 min-w-0 flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm text-muted hover:text-heading hover:bg-surface-alt transition-colors"
                >
                  <span class="w-2.5 h-2.5 rounded-sm flex-shrink-0" style={"background-color: #{cat.color}"}></span>
                  <span class="truncate">{cat.name}</span>
                </.link>
                <%!-- Toggling is owned by the CategoryTree hook, not JS.toggle:
                      a client-side class change gets reverted by the next
                      LiveView patch, so the list snapped shut on every
                      navigation. --%>
                <button
                  :if={children != []}
                  type="button"
                  data-cat-toggle={cat.id}
                  aria-controls={"subcats-#{cat.id}"}
                  aria-expanded="false"
                  aria-label={gettext("Show subcategories of %{name}", name: cat.name)}
                  class="flex-shrink-0 p-1 mr-1 rounded text-muted hover:text-heading hover:bg-surface-alt transition-colors"
                >
                  <.icon name="chevron-right" class="w-3.5 h-3.5 transition-transform" />
                </button>
              </div>

              <%!-- Collapsed by default: Racing alone has four children, which
                    pushed every other category below the fold. --%>
              <div
                :if={children != []}
                id={"subcats-#{cat.id}"}
                data-cat-subs={cat.id}
                class="hidden mt-0.5 space-y-0.5"
              >
                <.link
                  :for={child <- children}
                  navigate={~p"/c/#{child.slug}"}
                  title={child.name}
                  class="flex items-start gap-2 pl-7 pr-3 py-1 rounded-lg text-sm text-muted hover:text-heading hover:bg-surface-alt transition-colors"
                >
                  <span class="w-2 h-2 mt-1.5 rounded-sm flex-shrink-0" style={"background-color: #{child.color}"}></span>
                  <%!-- Wraps instead of truncating: "Competencias y Partidos"
                        was rendering as "Competencias y Parti…". --%>
                  <span class="leading-snug">{child.name}</span>
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- Tags: public, sits directly under Categories. Unlike the admin
              "Tags" entry below, this is a browse affordance for everyone. --%>
        <div :if={@sidebar_tags != []}>
          <h3 class="px-3 mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
            {gettext("Tags")}
          </h3>
          <div class="flex flex-wrap gap-1.5 px-3">
            <.link
              :for={tag <- @sidebar_tags}
              navigate={~p"/tag/#{tag.slug}"}
              class="inline-flex items-center gap-1 rounded-full bg-surface-alt border border-border px-2 py-0.5 text-xs text-muted hover:text-heading hover:border-border-hover transition-colors"
            >
              <span class="truncate max-w-[9rem]">{tag.name}</span>
              <span class="tabular-nums opacity-60">{tag.topic_count}</span>
            </.link>
          </div>
          <%!-- The list above is only the top 12, so without this the rest of
                the tags had no route in from the UI at all. --%>
          <.link
            navigate={~p"/tags"}
            class="block px-3 mt-2 text-xs text-muted hover:text-heading transition-colors"
          >
            {gettext("See all tags")} →
          </.link>
        </div>

        <div :if={Permissions.can_any?(@current_user, [:view_dashboard, :view_users, :manage_categories])}>
          <h3 class="px-3 mb-2 text-xs font-semibold uppercase tracking-wide text-muted">
            {gettext("Administration")}
          </h3>
          <div class="space-y-1">
            <.nav_link
              :if={Permissions.can?(@current_user, :view_dashboard)}
              navigate={~p"/admin"}
              icon="bar-chart-3"
              label={gettext("Dashboard")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :resolve_flags)}
              navigate={~p"/admin/moderation"}
              icon="shield"
              label={gettext("Moderation")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_users)}
              navigate={~p"/admin/users"}
              icon="users"
              label={gettext("Users")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :manage_categories)}
              navigate={~p"/admin/categories"}
              icon="hash"
              label={gettext("Categories")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :manage_categories)}
              navigate={~p"/admin/tags"}
              icon="tag"
              label={gettext("Tags")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :manage_badges)}
              navigate={~p"/admin/badges"}
              icon="star"
              label={gettext("Badges")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_dashboard)}
              navigate={~p"/admin/emojis"}
              icon="smile"
              label={gettext("Emoji")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_dashboard)}
              navigate={~p"/admin/stickers"}
              icon="sticker"
              label={gettext("Stickers")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :manage_bots)}
              navigate={~p"/admin/bots"}
              icon="zap"
              label={gettext("Bots")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_llm_settings)}
              navigate={~p"/admin/settings/llm"}
              icon="cpu"
              label={gettext("LLM / IA")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_dashboard)}
              navigate={~p"/admin/sofascore"}
              icon="activity"
              label="Sofascore"
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :manage_automations)}
              navigate={~p"/admin/automations"}
              icon="refresh-cw"
              label={gettext("Automations")}
            />
            <.nav_link
              :if={Permissions.can?(@current_user, :view_settings)}
              navigate={~p"/admin/settings"}
              icon="settings"
              label={gettext("Settings")}
            />
          </div>
        </div>
      </nav>
    </aside>
    """
  end

  # --- private helpers ---

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-3 px-3 py-1.5 rounded-lg text-sm font-medium text-muted hover:text-heading hover:bg-surface-alt transition-colors"
    >
      <.icon name={@icon} class="w-4 h-4" />
      {@label}
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp menu_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center gap-2 px-3 py-2 text-sm text-muted hover:text-heading hover:bg-surface-alt"
    >
      <.icon name={@icon} class="w-4 h-4" />
      {@label}
    </.link>
    """
  end

  attr :user, :any, required: true
  attr :class, :string, default: "w-8 h-8"

  defp user_avatar(assigns) do
    ~H"""
    <%= if @user.avatar_url do %>
      <img src={@user.avatar_url} alt={@user.username} class={["rounded-full object-cover", @class]} />
    <% else %>
      <span class={[
        "rounded-full bg-accent-soft text-accent flex items-center justify-center text-sm font-semibold uppercase",
        @class
      ]}>
        {String.first(@user.username || "?")}
      </span>
    <% end %>
    """
  end
end
