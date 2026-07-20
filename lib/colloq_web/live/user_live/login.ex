defmodule ColloqWeb.UserLive.Login do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias ColloqWeb.UserAuth

  def mount(params, _session, socket) do
    form =
      to_form(%{"email" => "", "password" => ""},
        as: :user,
        errors: [],
        action: nil
      )

    {:ok,
     socket
     |> assign(form: form)
     |> assign(:suspended_notice, suspended_notice(params))}
  end

  # Spanish suspension/ban banner text, built from the query params set by
  # SessionController.suspended/2. `nil` when the visitor isn't blocked.
  defp suspended_notice(%{"blocked" => "banned"}),
    do:
      "Tu cuenta fue suspendida de forma permanente. Si creés que es un error, contactá a un moderador."

  defp suspended_notice(%{"blocked" => "suspended", "until" => iso}) do
    case DateTime.from_iso8601(iso) do
      {:ok, until, _} ->
        "Tu cuenta está suspendida hasta el #{format_until(until)}. No podés publicar ni interactuar hasta entonces."

      _ ->
        "Tu cuenta está suspendida. No podés publicar ni interactuar por ahora."
    end
  end

  defp suspended_notice(%{"blocked" => "suspended"}),
    do: "Tu cuenta está suspendida. No podés publicar ni interactuar por ahora."

  defp suspended_notice(_), do: nil

  # Argentina local time, falling back to UTC if tz data is unavailable.
  defp format_until(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "America/Argentina/Buenos_Aires") do
      {:ok, local} -> Calendar.strftime(local, "%d/%m/%Y %H:%M") <> " (hora de Argentina)"
      _ -> Calendar.strftime(dt, "%d/%m/%Y %H:%M UTC")
    end
  end

  def handle_event("validate", %{"user" => params}, socket) do
    form = to_form(params, as: :user, errors: validate_login(params), action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"user" => %{"email" => email, "password" => password}}, socket) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        if Accounts.requires_2fa?(user) do
          {:noreply, UserAuth.log_in_user_pending_2fa(socket, user)}
        else
          {:noreply, UserAuth.log_in_user(socket, user)}
        end

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Incorrect email or password."))
          |> assign(form: to_form(%{"email" => email}, as: :user, errors: [], action: nil))}

      {:error, :too_many_attempts} ->
        {:noreply,
         socket
         |> put_flash(:error, "Demasiados intentos. Probá de nuevo en unos minutos.")
         |> assign(form: to_form(%{"email" => email}, as: :user, errors: [], action: nil))}
    end
  end

  defp validate_login(%{"email" => email, "password" => password}) do
    errors = []

    errors =
      if is_nil(email) || String.trim(email) == "" do
        [{"email", gettext("Email is required")} | errors]
      else
        errors
      end

    errors =
      if is_nil(password) || String.trim(password) == "" do
        [{"password", gettext("Password is required")} | errors]
      else
        errors
      end

    errors
  end

  defp validate_login(_), do: [{"email", gettext("Email is required")}, {"password", gettext("Password is required")}]

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <div class="mb-6 text-center">
        <h1 class="text-2xl font-bold text-white"><%= gettext("Welcome") %></h1>
        <p class="text-gray-400 text-sm mt-1"><%= gettext("The Argentine football community") %></p>
      </div>

      <div
        :if={@suspended_notice}
        class="mb-4 flex items-start gap-3 rounded-xl border border-danger/50 bg-danger-soft px-4 py-3"
      >
        <.icon name="ban" class="w-5 h-5 text-danger flex-shrink-0 mt-0.5" />
        <div>
          <p class="text-sm font-semibold text-danger">Cuenta suspendida</p>
          <p class="text-sm text-body mt-0.5"><%= @suspended_notice %></p>
        </div>
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
