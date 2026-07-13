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
          |> put_flash(:info, gettext("Account created! You can now log in."))
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
        <h1 class="text-xl font-bold text-white mb-6 text-center"><%= gettext("Create account") %></h1>

        <.form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            placeholder="tu@email.com"
            required
          />
          <.input
            field={@form[:username]}
            type="text"
            label={gettext("Username")}
            placeholder="user123"
            required
          />
          <.input
            field={@form[:display_name]}
            type="text"
            label={gettext("Display name")}
            placeholder={gettext("Your name")}
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            placeholder={gettext("minimum 8 characters")}
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            placeholder={gettext("Repeat password")}
            required
          />

          <.button type="submit" class="w-full mt-2">
            <%= gettext("Sign up") %>
          </.button>
        </.form>

        <p class="text-sm text-gray-400 text-center mt-4">
          <%= gettext("Already have an account?") %> <.link href="/login" class="text-blue-400 hover:text-blue-300"><%= gettext("Log in") %></.link>
        </p>
      </.card>
    </div>
    """
  end
end
