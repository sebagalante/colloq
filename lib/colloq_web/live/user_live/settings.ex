defmodule ColloqWeb.UserLive.Settings do
  use ColloqWeb, :live_view

  alias Colloq.Accounts

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

      {:ok, socket}
    else
      {:ok, push_redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{} = params, socket) do
    user = socket.assigns.current_user

    avatar_url =
      case consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name)
        filename = "avatar_#{user.id}_#{System.unique_integer([:positive])}#{ext}"
        data = File.read!(path)

        case Colloq.Media.upload(data, filename: filename, content_type: entry.client_type) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:error, reason}
        end
      end) do
        [url] -> url
        [] -> nil
      end

    attrs = %{
      "username" => params["username"],
      "display_name" => params["display_name"],
      "bio" => params["bio"],
      "location" => params["location"],
      "website" => params["website"],
      "flair" => params["flair"],
      "theme" => params["theme"],
      "locale" => params["locale"],
      "notifications_enabled" => params["notifications_enabled"] == "true",
      "allow_messages" => params["allow_messages"] == "true"
    }

    attrs = if avatar_url, do: Map.put(attrs, "avatar_url", avatar_url), else: attrs

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:form_data, attrs)
         # The <html> theme class is rendered once server-side; push the new
         # theme to the client so it applies live without a full page reload.
         |> push_event("set-theme", %{theme: updated_user.theme})
         |> put_flash(:info, gettext("Profile updated successfully."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         # Keep what the user typed (e.g. a taken username) instead of reverting.
         |> assign(:form_data, attrs)
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

  def handle_event("unblock-user", %{"user_id" => user_id}, socket) do
    actor = socket.assigns.current_user

    case Accounts.unblock_user(actor.id, String.to_integer(user_id)) do
      {:ok, _} ->
        blocked_users = Accounts.list_blocked_users(actor.id)

        {:noreply,
         socket
         |> assign(:blocked_users, blocked_users)
         |> put_flash(:info, "Usuario desbloqueado.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No se pudo desbloquear al usuario.")}
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
         |> put_flash(:info, "Autenticación de dos pasos activada.")}

      {:error, :invalid_code} ->
        {:noreply, put_flash(socket, :error, "Código incorrecto. Probá de nuevo.")}
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
         |> put_flash(:info, "Autenticación de dos pasos desactivada.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Código incorrecto.")}
    end
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

  defp upload_error_to_string(:too_large), do: gettext("File is too large (max 2MB).")
  defp upload_error_to_string(:not_accepted), do: gettext("File type not accepted.")
  defp upload_error_to_string(:too_many_files), do: gettext("Only one file allowed.")
  defp upload_error_to_string(err), do: gettext("Upload error: %{err}", err: inspect(err))
end
