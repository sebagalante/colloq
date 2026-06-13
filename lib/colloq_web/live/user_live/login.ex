defmodule ColloqWeb.UserLive.Login do
  use ColloqWeb, :live_view

  alias Colloq.Accounts

  def mount(_params, _session, socket) do
    form =
      to_form(%{"email" => "", "password" => ""},
        errors: [],
        action: nil
      )

    {:ok, assign(socket, form: form)}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    form = to_form(params, errors: validate_login(params), action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => %{"email" => email, "password" => password}}, socket) do
    case Accounts.authenticate_user(email, password) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "¡Bienvenido de vuelta!")
         |> redirect(to: "/")}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> put_flash(:error, "Email o contraseña incorrectos.")
          |> assign(form: to_form(%{"email" => email}, errors: [], action: nil))}
    end
  end

  defp validate_login(%{"email" => email, "password" => password}) do
    errors = []

    errors =
      if is_nil(email) || String.trim(email) == "" do
        [{"email", "El email es obligatorio"} | errors]
      else
        errors
      end

    errors =
      if is_nil(password) || String.trim(password) == "" do
        [{"password", "La contraseña es obligatoria"} | errors]
      else
        errors
      end

    errors
  end

  defp validate_login(_), do: [{"email", "El email es obligatorio"}, {"password", "La contraseña es obligatoria"}]

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <div class="mb-6 text-center">
        <h1 class="text-2xl font-bold text-white">Bienvenido</h1>
        <p class="text-gray-400 text-sm mt-1">La comunidad de fútbol argentino</p>
      </div>

      <.card>
        <.form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            placeholder="tu@email.com"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Contraseña"
            placeholder="Tu contraseña"
            required
          />

          <div class="text-right text-sm mb-4">
            <.link href="/forgot-password" class="text-blue-400 hover:text-blue-300">
              ¿Olvidaste tu contraseña?
            </.link>
          </div>

          <.button type="submit" class="w-full">
            Iniciar sesión
          </.button>
        </.form>

        <p class="text-sm text-gray-400 text-center mt-4">
          ¿No tenés cuenta? <.link href="/register" class="text-blue-400 hover:text-blue-300">Registrate</.link>
        </p>
      </.card>
    </div>
    """
  end
end
