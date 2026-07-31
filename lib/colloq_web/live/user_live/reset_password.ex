defmodule ColloqWeb.UserLive.ResetPassword do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Accounts.User
  alias Colloq.Repo

  # Phoenix.Token.verify/4 takes `max_age` in SECONDS. `:timer.hours(1)` is
  # milliseconds — passing it made reset links live ~41 days instead of 1 hour.
  @token_max_age 3600

  def mount(params, _session, socket) do
    token = params["token"]

    user =
      if token do
        case Phoenix.Token.verify(ColloqWeb.Endpoint, "reset_password", token,
               max_age: @token_max_age
             ) do
          {:ok, user_id} -> Accounts.get_user(user_id)
          {:error, _reason} -> nil
        end
      end

    form =
      to_form(%{"password" => "", "password_confirmation" => ""},
        as: :user,
        errors: [],
        action: nil
      )

    {:ok,
     assign(socket,
       form: form,
       token: token,
       user: user,
       submitted: false
     )}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    errors = validate_password(params)
    form = to_form(params, as: :user, errors: errors, action: :validate)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event(
        "save",
        %{"user" => %{"password" => password, "password_confirmation" => confirmation}},
        socket
      ) do
    user = socket.assigns.user

    cond do
      is_nil(user) ->
        {:noreply,
         socket
         |> put_flash(:error, "El enlace de recuperación es inválido o expiró.")
         |> assign(submitted: false)}

      password != confirmation ->
        form =
          to_form(%{"password" => "", "password_confirmation" => ""},
            as: :user,
            errors: [{"password_confirmation", "Las contraseñas no coinciden"}],
            action: :validate
          )

        {:noreply,
         socket
         |> assign(form: form, submitted: false)}

      String.length(password) < 8 ->
        form =
          to_form(%{"password" => password, "password_confirmation" => confirmation},
            as: :user,
            errors: [{"password", "La contraseña debe tener al menos 8 caracteres"}],
            action: :validate
          )

        {:noreply,
         socket
         |> assign(form: form, submitted: false)}

      true ->
        # Goes through the same changeset registration uses, so the length and
        # confirmation rules can't drift between the two ways to set a password
        # — and the hashing lives in one place.
        case user
             |> User.password_changeset(%{
               password: password,
               password_confirmation: confirmation
             })
             |> Repo.update() do
          {:ok, _user} ->
            {:noreply,
             socket
             |> put_flash(:info, "¡Contraseña actualizada con éxito! Ya podés iniciar sesión.")
             |> redirect(to: "/login")}

          {:error, _changeset} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               "Ocurrió un error al actualizar la contraseña. Intentá de nuevo."
             )}
        end
    end
  end

  defp validate_password(%{"password" => password, "password_confirmation" => confirmation}) do
    errors = []

    errors =
      if is_nil(password) || String.trim(password) == "" do
        [{"password", "La contraseña es obligatoria"} | errors]
      else
        cond do
          String.length(password) < 8 ->
            [{"password", "La contraseña debe tener al menos 8 caracteres"} | errors]

          # Mirrors the 72-byte bcrypt limit enforced in User.password_changeset,
          # so the form says so before the submit fails.
          byte_size(password) > 72 ->
            [{"password", "La contraseña no puede superar los 72 caracteres"} | errors]

          true ->
            errors
        end
      end

    errors =
      if is_nil(confirmation) || String.trim(confirmation) == "" do
        [{"password_confirmation", "La confirmación es obligatoria"} | errors]
      else
        if password != confirmation do
          [{"password_confirmation", "Las contraseñas no coinciden"} | errors]
        else
          errors
        end
      end

    errors
  end

  defp validate_password(_),
    do: [
      {"password", "La contraseña es obligatoria"},
      {"password_confirmation", "La confirmación es obligatoria"}
    ]

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <.card>
        <h1 class="text-xl font-bold text-white mb-2 text-center">Restablecer contraseña</h1>
        <p class="text-gray-400 text-sm text-center mb-6">
          Elegí una nueva contraseña para tu cuenta.
        </p>

        <.form :if={!is_nil(@user)} for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:password]}
            type="password"
            label="Nueva contraseña"
            placeholder="Mínimo 8 caracteres"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirmar nueva contraseña"
            placeholder="Repetí la contraseña"
            required
          />

          <.button type="submit" class="w-full">
            Actualizar contraseña
          </.button>
        </.form>

        <p :if={is_nil(@user)} class="text-red-400 text-sm text-center">
          El enlace de recuperación es inválido o expiró.
        </p>

        <p class="text-sm text-gray-400 text-center mt-4">
          <.link href="/login" class="text-blue-400 hover:text-blue-300">
            Volver al inicio de sesión
          </.link>
        </p>
      </.card>
    </div>
    """
  end
end
