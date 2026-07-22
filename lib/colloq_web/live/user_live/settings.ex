defmodule ColloqWeb.UserLive.Settings do
  @moduledoc """
  Account settings, split into linkable panes at `/settings/:tab`.

  Only the active pane is rendered, so `save` merges just the fields that were
  actually submitted (see `changed_attrs/1`) rather than assuming every field
  is present in the params.
  """
  use ColloqWeb, :live_view

  alias Colloq.Accounts

  @tabs ~w(account profile preferences appearance security)
  @default_tab "account"

  # Fields owned by the main settings form, grouped by how they're cast.
  @text_fields ~w(username display_name bio location website flair theme locale)
  @bool_fields ~w(notifications_enabled allow_messages)

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case session["user_id"] do
        nil -> nil
        user_id -> Accounts.get_user!(user_id)
      end

    if current_user do
      blocked_users = Accounts.list_blocked_users(current_user.id)

      socket =
        socket
        |> assign(:current_user, current_user)
        |> assign(:changeset, Accounts.User.update_changeset(current_user, %{}))
        |> assign(:page_title, gettext("Settings"))
        |> assign(:blocked_users, blocked_users)
        |> assign(:form_data, %{
          "username" => current_user.username || "",
          "display_name" => current_user.display_name || "",
          "bio" => current_user.bio || "",
          "location" => current_user.location || "",
          "website" => current_user.website || "",
          "flair" => current_user.flair || "",
          "theme" => current_user.theme || "dark",
          "locale" => current_user.locale || "es",
          "notifications_enabled" => current_user.notifications_enabled,
          "allow_messages" => current_user.allow_messages
        })
        # 2FA setup state
        |> assign(:setup_2fa, false)
        |> assign(:qr_svg, nil)
        |> assign(:totp_secret, nil)
        |> assign(:backup_codes, nil)
        |> assign(:verify_code, "")
        |> assign(:disable_2fa_code, "")
        |> assign(:show_disable_2fa, false)
        |> allow_upload(:avatar,
          accept: ~w(.jpg .jpeg .png .gif .webp),
          max_entries: 1,
          max_file_size: 2_000_000  # 2MB
        )
        # Banners are wide, so they get a larger budget than the avatar.
        |> allow_upload(:profile_header,
          accept: ~w(.jpg .jpeg .png .gif .webp),
          max_entries: 1,
          max_file_size: 5_000_000
        )
        |> allow_upload(:card_background,
          accept: ~w(.jpg .jpeg .png .gif .webp),
          max_entries: 1,
          max_file_size: 5_000_000
        )

      {:ok, socket}
    else
      {:ok, push_redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: @default_tab
    {:noreply, assign(socket, :tab, tab)}
  end

  @doc """
  Tabs rendered in the settings sub-navigation, in order.
  """
  def tabs do
    [
      %{id: "account", label: gettext("Account"), icon: "at-sign"},
      %{id: "profile", label: gettext("Profile"), icon: "user"},
      %{id: "preferences", label: gettext("Preferences"), icon: "sliders-horizontal"},
      %{id: "appearance", label: gettext("Appearance"), icon: "palette"},
      %{id: "security", label: gettext("Security"), icon: "shield"}
    ]
  end

  @doc """
  Theme catalogue driving both the picker and its live preview.

  `bg`/`border`/`bar` accept any CSS colour, so the built-in dark and light
  themes can follow the current CSS variables while the custom ones pin hexes.
  """
  def themes do
    [
      %{id: "dark", label: gettext("Dark"), caption: nil,
        bg: "var(--surface)", border: "var(--border)", bar: "var(--border)",
        dots: ~w(#ef4444 #f59e0b #22c55e), accent: "var(--text-muted)"},
      %{id: "light", label: gettext("Light"), caption: nil,
        bg: "#ffffff", border: "#e5e7eb", bar: "#e5e7eb",
        dots: ~w(#f87171 #fbbf24 #4ade80), accent: "#6b7280"},
      %{id: "racing_light", label: "Racing Light", caption: "La Academia · celeste",
        bg: "#AFD4EF", border: "#93BFE3", bar: "#93BFE3",
        dots: ~w(#0038A8 #2C6FC4 #CFE4F6), accent: "#0038A8"},
      %{id: "racing_celeste", label: "Racing Celeste", caption: "La Academia · celeste profundo",
        bg: "#7FB3DB", border: "#5E97CC", bar: "#5E97CC",
        dots: ~w(#002F8F #1E5AAD #99C4E5), accent: "#002F8F"},
      %{id: "racing_navy", label: "Racing Navy", caption: "La Academia · navy profundo",
        bg: "#0C1B33", border: "#16304F", bar: "#16304F",
        dots: ~w(#5CB8E6 #0038A8 #ffffff), accent: "#5CB8E6"},
      %{id: "racing_salmon", label: "Racing Salmón", caption: "Racing · azul y salmón",
        bg: "#123050", border: "#1E4468", bar: "#1E4468",
        dots: ~w(#FF8E72 #5CB8E6 #ffffff), accent: "#FF8E72"},
      %{id: "dracula", label: "Dracula", caption: "Dracula",
        bg: "#282a36", border: "#44475a", bar: "#44475a",
        dots: ~w(#bd93f9 #ff79c6 #50fa7b), accent: "#bd93f9"},
      %{id: "tokyo_night", label: "Tokyo Night", caption: "Tokyo Night",
        bg: "#1a1b26", border: "#292e42", bar: "#292e42",
        dots: ~w(#7aa2f7 #bb9af7 #9ece6a), accent: "#7aa2f7"}
    ]
  end

  @doc """
  True when `theme_id` is the user's current selection.

  "racing" is the legacy id for what is now "racing_navy".
  """
  def theme_selected?("racing_navy", current), do: current in ["racing_navy", "racing"]
  def theme_selected?(id, current), do: id == current

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{} = params, socket) do
    user = socket.assigns.current_user

    attrs =
      params
      |> changed_attrs()
      |> put_upload(socket, :avatar, "avatar_url", user)
      |> put_upload(socket, :profile_header, "profile_header_url", user)
      |> put_upload(socket, :card_background, "card_background_url", user)

    # Only the active pane is in the DOM, so merge over what's already on screen
    # instead of replacing it — otherwise switching tabs would blank the rest.
    form_data = Map.merge(socket.assigns.form_data, attrs)

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:form_data, form_data)
         # The <html> theme class is rendered once server-side; push the new
         # theme to the client so it applies live without a full page reload.
         |> push_event("set-theme", %{theme: updated_user.theme})
         |> put_flash(:info, gettext("Profile updated successfully."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         # Keep what the user typed (e.g. a taken username) instead of reverting.
         |> assign(:form_data, form_data)
         |> put_flash(:error, error_message(changeset))}
    end
  end

  def handle_event("remove-avatar", _params, socket) do
    user = socket.assigns.current_user

    case Accounts.update_user(user, %{"avatar_url" => nil}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Avatar removed."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove avatar."))}
    end
  end

  def handle_event("remove-image", %{"field" => field}, socket)
      when field in ~w(profile_header_url card_background_url) do
    case Accounts.update_user(socket.assigns.current_user, %{field => nil}) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Image removed."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the image."))}
    end
  end

  def handle_event("unblock-user", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user

    case Accounts.unblock_user(actor.id, String.to_integer(user_id)) do
      {:ok, _} ->
        blocked_users = Accounts.list_blocked_users(actor.id)

        {:noreply,
         socket
         |> assign(:blocked_users, blocked_users)
         |> put_flash(:info, gettext("User unblocked."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not unblock the user."))}
    end
  end

  # =========================================================================
  # 2FA Setup Events
  # =========================================================================

  def handle_event("start-2fa-setup", _params, socket) do
    user = socket.assigns.current_user
    {user, secret} = Accounts.generate_totp_secret(user)
    uri = Accounts.totp_provisioning_uri(user, secret)

    {:ok, svg} =
      uri
      |> EQRCode.encode()
      |> EQRCode.svg(width: 200)

    {:noreply,
     socket
     |> assign(:setup_2fa, true)
     |> assign(:qr_svg, svg)
     |> assign(:totp_secret, secret)
     |> assign(:current_user, user)}
  end

  def handle_event("cancel-2fa-setup", _params, socket) do
    user = socket.assigns.current_user
    {:ok, user} = Accounts.cancel_totp_setup(user)

    {:noreply,
     socket
     |> assign(:setup_2fa, false)
     |> assign(:qr_svg, nil)
     |> assign(:totp_secret, nil)
     |> assign(:backup_codes, nil)
     |> assign(:verify_code, "")
     |> assign(:current_user, user)}
  end

  def handle_event("verify-2fa", %{"code" => code}, socket) do
    user = socket.assigns.current_user
    code = String.trim(code)

    case Accounts.enable_totp(user, code) do
      {:ok, backup_codes} ->
        user = Accounts.get_user!(user.id)

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:backup_codes, backup_codes)
         |> assign(:setup_2fa, false)
         |> assign(:qr_svg, nil)
         |> assign(:totp_secret, nil)
         |> assign(:verify_code, "")
         |> put_flash(:info, gettext("Two-factor authentication turned on."))}

      {:error, :invalid_code} ->
        {:noreply, put_flash(socket, :error, gettext("Incorrect code. Try again."))}
    end
  end

  def handle_event("show-disable-2fa", _params, socket) do
    {:noreply, assign(socket, :show_disable_2fa, true)}
  end

  def handle_event("cancel-disable-2fa", _params, socket) do
    {:noreply, assign(socket, :show_disable_2fa, false)}
  end

  def handle_event("disable-2fa", %{"code" => code}, socket) do
    user = socket.assigns.current_user
    code = String.trim(code)

    case Accounts.verify_totp(user, code) do
      :ok ->
        {:ok, user} = Accounts.disable_totp(user)

        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:show_disable_2fa, false)
         |> put_flash(:info, gettext("Two-factor authentication turned off."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Incorrect code."))}
    end
  end

  # Consume one upload slot, if it has an entry, and fold the resulting URL into
  # attrs under `field`. No entry means the key is left untouched, so saving a
  # different pane never clears an existing image.
  defp put_upload(attrs, socket, upload_name, field, user) do
    uploaded =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name)
        filename = "#{upload_name}_#{user.id}_#{System.unique_integer([:positive])}#{ext}"

        case Colloq.Media.upload(File.read!(path),
               filename: filename,
               content_type: entry.client_type
             ) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:error, reason}
        end
      end)

    case uploaded do
      [url] -> Map.put(attrs, field, url)
      [] -> attrs
    end
  end

  # Build attrs from only the fields the submitted pane actually contained, so
  # saving one tab never blanks fields belonging to another. Each toggle ships a
  # hidden "false" input, so an unchecked box is still present in the params.
  defp changed_attrs(params) do
    text =
      for k <- @text_fields, Map.has_key?(params, k), into: %{}, do: {k, params[k]}

    bools =
      for k <- @bool_fields, Map.has_key?(params, k), into: %{}, do: {k, params[k] == "true"}

    Map.merge(text, bools)
  end

  # Surface the username problem specifically — it's the field most likely to
  # fail (taken / bad format) and a generic "check the fields" hides why.
  defp error_message(changeset) do
    case Keyword.get(changeset.errors, :username) do
      {"has already been taken", _} -> gettext("That username is already taken.")
      {msg, _} -> "#{gettext("Username")}: #{msg}"
      nil -> gettext("Could not save. Check the fields.")
    end
  end

end
