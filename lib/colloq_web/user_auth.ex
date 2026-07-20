defmodule ColloqWeb.UserAuth do
  import Phoenix.LiveView
  import Phoenix.Component
  import Plug.Conn, only: [get_session: 2, halt: 1]
  import ColloqWeb.Gettext

  @moduledoc """
  Authentication helpers for LiveViews and controllers.
  """

  alias Colloq.Accounts
  alias Colloq.Forum
  alias Colloq.Permissions

  def on_mount(:default, _params, session, socket) do
    user = session["user_id"] && Accounts.get_user(session["user_id"])

    cond do
      # Suspended and banned accounts get logged out on their next mount: the
      # controller drops the session and shows a Spanish banner with the end
      # date. Halting here keeps them from interacting in the meantime.
      user && interaction_blocked?(user) ->
        {:halt, redirect(socket, to: "/session/suspended")}

      true ->
        mount_default_user(socket, user)
    end
  end

  defp mount_default_user(socket, user) do
    locale = (user && user.locale) || "es"
    theme = (user && user.theme) || "dark"
    Gettext.put_locale(ColloqWeb.Gettext, locale)

    socket =
      socket
      |> assign(current_user: user)
      |> assign(locale: locale)
      |> assign(theme: theme)
      |> assign(unread_notifications: (user && Colloq.Notifications.unread_count(user.id)) || 0)
      |> assign(unread_messages: (user && Colloq.Messaging.unread_count(user.id)) || 0)
      # Restricted categories never reach the sidebar for non-staff.
      |> assign_new(:categories, fn -> Forum.list_categories(user) end)
      # Public: the sidebar tag list is visible to everyone, logged in or not.
      |> assign_new(:sidebar_tags, fn -> Colloq.Tags.popular_tags() end)

    socket =
      if user && Phoenix.LiveView.connected?(socket) do
        # Mark the user online for as long as this LiveView process lives.
        ColloqWeb.Presence.track_user(self(), user.id)

        # Live header badges: subscribe to a per-user channel and update the
        # unread counts on any page, via a global handle_info hook.
        Phoenix.PubSub.subscribe(Colloq.PubSub, "user:#{user.id}")
        attach_hook(socket, :live_badges, :handle_info, &live_badges_hook(&1, &2, user.id))
      else
        socket
      end

    {:cont, socket}
  end

  # Global handle_info for the live header badges. Runs on every LiveView.
  defp live_badges_hook(%{event: "message_received"}, socket, user_id) do
    {:halt, Phoenix.Component.assign(socket, :unread_messages, Colloq.Messaging.unread_count(user_id))}
  end

  defp live_badges_hook(%{event: "notification"}, socket, user_id) do
    {:halt,
     Phoenix.Component.assign(socket, :unread_notifications, Colloq.Notifications.unread_count(user_id))}
  end

  defp live_badges_hook(_msg, socket, _user_id), do: {:cont, socket}

  # Banned or actively-suspended accounts get no authenticated session.
  # (Silenced users keep theirs — they may read and are blocked from posting
  # by the domain-level check_can_post.)
  defp interaction_blocked?(user) do
    user.banned || Accounts.User.suspended?(user)
  end

  def on_mount(:require_user, _params, session, socket) do
    case session["user_id"] do
      nil ->
        Gettext.put_locale(ColloqWeb.Gettext, "es")

        socket =
          socket
          |> put_flash(:error, gettext("You must log in to access this page."))
          |> redirect(to: "/login")

        {:halt, socket}

      user_id ->
          user = Accounts.get_user!(user_id)
          theme = user.theme || "dark"
          Gettext.put_locale(ColloqWeb.Gettext, user.locale || "es")

          cond do
            user.banned ->
              socket =
                socket
                |> assign(current_user: nil)
                |> assign(theme: "dark")
                |> put_flash(:error, gettext("Your account has been banned."))
                |> redirect(to: "/login")

              {:halt, socket}

            Colloq.Accounts.User.suspended?(user) ->
              socket =
                socket
                |> assign(current_user: nil)
                |> assign(theme: "dark")
                |> put_flash(:error, gettext("Your account is suspended."))
                |> redirect(to: "/login")

              {:halt, socket}

            true ->
              {:cont, socket |> assign(current_user: user) |> assign(theme: theme)}
          end
    end
  end

  @doc """
  on_mount hook that checks if the current user has a specific permission.

  ## Usage in router

      live_session :admin,
        on_mount: [{ColloqWeb.UserAuth, {:require_permission, :view_dashboard}}] do
        live "/admin", AdminLive.Dashboard, :index
      end
  """
  def on_mount({:require_permission, permission}, _params, session, socket) do
    case session["user_id"] do
      nil ->
        socket =
          socket
          |> put_flash(:error, gettext("Access denied."))
          |> redirect(to: "/login")

        {:halt, socket}

      user_id ->
        user = Accounts.get_user!(user_id)
        theme = user.theme || "dark"
        Gettext.put_locale(ColloqWeb.Gettext, user.locale || "es")

        socket = socket |> assign(current_user: user) |> assign(theme: theme)

        if Permissions.can?(user, permission) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> put_flash(:error, gettext("Access denied."))
           |> redirect(to: "/")}
        end
    end
  end

  @doc """
  on_mount hook for admin access (any admin role).
  Kept for backward compatibility — prefer {:require_permission, :specific_permission}.
  """
  def on_mount(:require_admin, _params, session, socket) do
    case session["user_id"] do
      nil ->
        socket =
          socket
          |> put_flash(:error, gettext("Access denied."))
          |> redirect(to: "/")

        {:halt, socket}

      user_id ->
        user = Accounts.get_user!(user_id)
        theme = user.theme || "dark"
        Gettext.put_locale(ColloqWeb.Gettext, user.locale || "es")

        socket = socket |> assign(current_user: user) |> assign(theme: theme)

        if user.role in ~w(moderator admin super_admin) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> put_flash(:error, gettext("Access denied."))
           |> redirect(to: "/")}
        end
    end
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      user = Accounts.get_user(user_id)
      theme = if user, do: user.theme || "dark", else: "dark"
      locale = if user, do: user.locale || "es", else: "es"

      conn
      |> Plug.Conn.assign(:current_user, user)
      |> Plug.Conn.assign(:theme, theme)
      |> Plug.Conn.assign(:locale, locale)
    else
      conn
      |> Plug.Conn.assign(:current_user, nil)
      |> Plug.Conn.assign(:theme, "dark")
      |> Plug.Conn.assign(:locale, "es")
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "Debes iniciar sesión.")
      |> Phoenix.Controller.redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  Plug that requires any admin role (moderator, admin, or super_admin).
  """
  def require_admin_user(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && user.role in ~w(moderator admin super_admin) do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "Acceso denegado.")
      |> Phoenix.Controller.redirect(to: "/")
      |> halt()
    end
  end

  @doc """
  Plug that requires 2FA verification for admin/mod users with TOTP enabled.

  If the user has TOTP enabled and is admin/mod, checks for :_2fa_verified
  in the session. If not verified, redirects to /2fa.
  Regular users and users without TOTP pass through.
  """
  def require_2fa_verified(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && Accounts.requires_2fa?(user) && !get_session(conn, :_2fa_verified) do
      conn
      |> Phoenix.Controller.put_flash(:error, "Verificación de dos pasos requerida.")
      |> Phoenix.Controller.redirect(to: "/2fa")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Logs in a user by redirecting to the session controller.
  Used by LiveViews since they cannot modify sessions directly.
  """
  def log_in_user(socket, user) do
    token = Phoenix.Token.sign(ColloqWeb.Endpoint, "login", user.id)
    redirect(socket, to: "/session?token=#{token}")
  end

  @doc """
  Logs in a user that requires 2FA verification.
  Stores the user_id in a pending session key for the 2FA step.
  """
  def log_in_user_pending_2fa(socket, user) do
    token = Phoenix.Token.sign(ColloqWeb.Endpoint, "pending_2fa", user.id)
    redirect(socket, to: "/session/2fa?token=#{token}")
  end
end
