defmodule ColloqWeb.UserLive.Registration do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Accounts.User

  def mount(_params, _session, socket) do
    changeset = User.registration_changeset(%User{}, %{})
    {:ok, assign(socket, form: to_form(changeset), submitted: false)}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        socket =
          socket
          |> put_flash(:info, "¡Cuenta creada con éxito! Ya podés iniciar sesión.")
          |> redirect(to: "/login")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(%{changeset | action: :insert}))}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <.card>
        <h1 class="text-xl font-bold text-white mb-6 text-center">Crear cuenta</h1>

        <.form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            placeholder="tu@email.com"
            required
          />
          <.input
            field={@form[:username]}
            type="text"
            label="Nombre de usuario"
            placeholder="usuario123"
            required
          />
          <.input
            field={@form[:display_name]}
            type="text"
            label="Nombre visible"
            placeholder="Tu nombre"
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Contraseña"
            placeholder="Mínimo 8 caracteres"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirmar contraseña"
            placeholder="Repetí la contraseña"
            required
          />

          <.button type="submit" class="w-full mt-2">
            Crear cuenta
          </.button>
        </.form>

        <p class="text-sm text-gray-400 text-center mt-4">
          ¿Ya tenés cuenta? <.link href="/login" class="text-blue-400 hover:text-blue-300">Iniciar sesión</.link>
        </p>
      </.card>
    </div>
    """
  end
end
