defmodule ColloqWeb.UserLive.Settings do
  use ColloqWeb, :live_view

  alias Colloq.Accounts

  @impl true
  def mount(_params, session, socket) do
    current_user =
      case session["user_id"] do
        nil ->
          nil

        user_id ->
          Accounts.get_user!(user_id)
      end

    if current_user do
      socket =
        socket
        |> assign(:current_user, current_user)
        |> assign(:changeset, Accounts.User.update_changeset(current_user, %{}))
        |> assign(:page_title, "Configuración")
        |> assign(:form_data, %{
          "display_name" => current_user.display_name || "",
          "bio" => current_user.bio || "",
          "location" => current_user.location || "",
          "website" => current_user.website || "",
          "theme" => current_user.theme || "dark",
          "locale" => current_user.locale || "es",
          "notifications_enabled" => current_user.notifications_enabled
        })

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
  def handle_event("save", %{} = params, socket) do
    user = socket.assigns.current_user

    attrs = %{
      "display_name" => params["display_name"],
      "bio" => params["bio"],
      "location" => params["location"],
      "website" => params["website"],
      "theme" => params["theme"],
      "locale" => params["locale"],
      "notifications_enabled" => params["notifications_enabled"] == "true"
    }

    case Accounts.update_user(user, attrs) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:form_data, attrs)
         |> put_flash(:info, "Perfil actualizado correctamente.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)
         |> put_flash(:error, "No se pudo guardar. Revisá los campos.")}
    end
  end
end
