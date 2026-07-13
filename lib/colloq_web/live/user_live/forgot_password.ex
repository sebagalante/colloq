defmodule ColloqWeb.UserLive.ForgotPassword do
  use ColloqWeb, :live_view

  alias Colloq.Accounts

  def mount(_params, _session, socket) do
    form = to_form(%{"email" => ""}, as: :user, errors: [])
    {:ok, assign(socket, form: form, sent: false)}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    errors = validate_email(params)
    form = to_form(params, as: :user, errors: errors)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => %{"email" => email}}, socket) do
    user = Accounts.get_user_by_email(email)

    if user do
      token = Phoenix.Token.sign(ColloqWeb.Endpoint, "reset_password", user.id)

      %{
        "user_id" => user.id,
        "email" => user.email,
        "token" => token
      }
      |> Colloq.Workers.PasswordResetWorker.new()
      |> Oban.insert()
    end

    {:noreply,
     socket
     |> assign(sent: true)
     |> put_flash(:info, "Si el email existe, recibirás instrucciones para recuperar tu contraseña.")}
  end

  defp validate_email(%{"email" => email}) do
    if is_nil(email) || String.trim(email) == "" do
      [{"email", "El email es obligatorio"}]
    else
      []
    end
  end

  defp validate_email(_), do: [{"email", "El email es obligatorio"}]

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <.card>
        <h1 class="text-xl font-bold text-white mb-2 text-center">Recuperar contraseña</h1>

        <%= if @sent do %>
          <p class="text-gray-300 text-sm text-center">
            Si el email existe, recibirás instrucciones para recuperar tu contraseña.
          </p>
          <p class="text-center mt-4">
            <.link href="/login" class="text-blue-400 hover:text-blue-300 text-sm">
              Volver al inicio de sesión
            </.link>
          </p>
        <% else %>
          <p class="text-gray-400 text-sm text-center mb-6">
            Ingresá tu email y te enviaremos un enlace para restablecer tu contraseña.
          </p>

          <.form for={@form} phx-change="validate" phx-submit="save">
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              placeholder="tu@email.com"
              required
            />

            <.button type="submit" class="w-full">
              Enviar instrucciones
            </.button>
          </.form>

          <p class="text-sm text-gray-400 text-center mt-4">
            <.link href="/login" class="text-blue-400 hover:text-blue-300">
              Volver al inicio de sesión
            </.link>
          </p>
        <% end %>
      </.card>
    </div>
    """
  end
end
