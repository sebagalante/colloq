defmodule ColloqWeb.UserLive.TwoFactor do
  @moduledoc """
  LiveView for two-factor authentication verification during login.

  After email+password authentication, if the user has TOTP enabled,
  they are redirected here to enter their 6-digit code or a backup code.
  """
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias ColloqWeb.UserAuth

  @impl true
  def mount(_params, session, socket) do
    case session["pending_2fa_user_id"] do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(String.to_integer(user_id))

        socket =
          socket
          |> assign(:user, user)
          |> assign(:code, "")
          |> assign(:use_backup, false)
          |> assign(:page_title, "Verificación de dos pasos")

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"code" => code}, socket) do
    {:noreply, assign(socket, :code, code)}
  end

  def handle_event("verify", %{"code" => code}, socket) do
    user = socket.assigns.user
    code = String.trim(code)

    if code == "" do
      {:noreply, put_flash(socket, :error, "Ingresá el código.")}
    else
      case Accounts.verify_totp(user, code) do
        :ok ->
          # If it was a backup code, consume it
          if socket.assigns.use_backup do
            Accounts.consume_backup_code(user, code)
          end

          # LiveViews cannot write the session, so hand off to SessionController
          # with a short-lived signed token proving TOTP was verified here.
          token = Phoenix.Token.sign(ColloqWeb.Endpoint, "2fa_complete", user.id)
          {:noreply, redirect(socket, to: ~p"/session/2fa/complete?#{[token: token]}")}

        {:error, :invalid_code} ->
          {:noreply, put_flash(socket, :error, "Código incorrecto. Probá de nuevo.")}

        {:error, :code_already_used} ->
          {:noreply, put_flash(socket, :error, "Este código ya fue usado. Usá el siguiente.")}
      end
    end
  end

  def handle_event("toggle-backup", _params, socket) do
    {:noreply,
     socket
     |> assign(:use_backup, !socket.assigns.use_backup)
     |> assign(:code, "")}
  end

  def handle_event("resend-pending", _params, socket) do
    {:noreply, redirect(socket, to: "/login")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <div class="mb-6 text-center">
        <h1 class="text-2xl font-bold text-heading">Verificación de dos pasos</h1>
        <p class="text-muted text-sm mt-1">
          <%= if @use_backup do %>
            Ingresá uno de tus códigos de respaldo.
          <% else %>
            Ingresá el código de 6 dígitos de tu app autenticadora.
          <% end %>
        </p>
      </div>

      <.card>
        <form phx-submit="verify" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-muted mb-1">
              <%= if @use_backup, do: "Código de respaldo", else: "Código de verificación" %>
            </label>
            <input
              type="text"
              name="code"
              value={@code}
              phx-change="validate"
              placeholder={if @use_backup, do: "ej: abc12345", else: "000000"}
              maxlength={if @use_backup, do: 8, else: 6}
              autocomplete="one-time-code"
              autofocus
              class={"w-full rounded-lg border border-border bg-surface text-heading px-3 py-2 text-sm text-center focus:outline-none focus:ring-2 focus:ring-accent #{if @use_backup, do: "font-mono tracking-wider", else: "text-2xl tracking-[0.5em] font-mono"}"}
            />
          </div>

          <.button type="submit" class="w-full">
            Verificar
          </.button>
        </form>

        <div class="mt-4 text-center space-y-2">
          <button
            type="button"
            phx-click="toggle-backup"
            class="text-sm text-accent hover:text-accent-hover transition-colors"
          >
            <%= if @use_backup, do: "Usar código de autenticador", else: "Usar código de respaldo" %>
          </button>

          <p class="text-xs text-muted">
            ¿No tenés acceso? <.link href="/login" class="text-accent hover:underline">Volver al login</.link>
          </p>
        </div>
      </.card>
    </div>
    """
  end
end
