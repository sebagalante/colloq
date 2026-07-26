defmodule ColloqWeb.UserLive.Registration do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Accounts.User
  alias Colloq.Invites

  def mount(params, _session, socket) do
    # `registration_mode` gates this page: open lets anyone through, closed nobody,
    # invite only the holder of a live token from the ?invite= link.
    token = params["invite"]
    invite = Invites.pending_by_token(token)

    # Prefill the invited address: the invite is bound to it, so letting them
    # type a different one would only fail at save.
    initial = if invite, do: %{"email" => invite.email}, else: %{}
    changeset = User.registration_changeset(%User{}, initial)

    {:ok,
     socket
     |> assign(form: to_form(changeset), submitted: false)
     |> assign(invite: invite, invite_token: token)
     |> assign(client_ip: client_ip(socket))
     |> assign(gate: Invites.registration_open?(token))}
  end

  # The address this signup came from, recorded on the account for moderation.
  #
  # `peer_data` is Caddy on loopback in production, so the forwarded chain is
  # walked with the same trusted-proxy list the RemoteIp plug uses — otherwise
  # every account would be stamped 127.0.0.1. nil on the disconnected mount
  # (there is no connect_info yet), which is fine: the value is read on submit,
  # by which point the socket is connected.
  defp client_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = get_connect_info(socket, :x_headers) || []

        case RemoteIp.from(headers, proxies: ColloqWeb.Endpoint.trusted_proxies()) do
          nil -> address
          forwarded -> forwarded
        end

      _ ->
        nil
    end
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{}
      |> User.registration_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    # Re-checked here, not just in mount: the mode can change mid-session, and a
    # client can submit the form without ever rendering the gated page.
    token = socket.assigns.invite_token

    case Invites.registration_open?(token) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, gate_message(reason))}

      :ok ->
        invite = Invites.pending_by_token(token)
        params = if invite, do: Map.put(params, "email", invite.email), else: params

        case Accounts.register_user(params, socket.assigns.client_ip) do
          {:ok, user} ->
            if invite, do: Invites.accept(invite, user)

            {:noreply,
             socket
             |> put_flash(:info, gettext("Account created! You can now log in."))
             |> redirect(to: "/login")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, form: to_form(%{changeset | action: :insert}))}
        end
    end
  end

  defp gate_message(:closed), do: gettext("Registration is closed right now.")

  defp gate_message(:invite_required),
    do: gettext("You need a valid invitation to create an account.")

  def render(assigns) do
    ~H"""
    <div class="max-w-md mx-auto mt-12 px-4">
      <.card>
        <h1 class="text-xl font-bold text-white mb-6 text-center"><%= gettext("Create account") %></h1>

        <%!-- Signup blocked (closed, or invite-only without a live token): explain
              it instead of showing a form that can only fail on submit. --%>
        <div :if={@gate != :ok} class="space-y-4 text-center">
          <p class="text-sm text-muted">
            <%= gate_message(elem(@gate, 1)) %>
          </p>
          <p class="text-sm text-gray-400">
            <%= gettext("Already have an account?") %>
            <.link href="/login" class="text-blue-400 hover:text-blue-300">
              <%= gettext("Log in") %>
            </.link>
          </p>
        </div>

        <.form :if={@gate == :ok} for={@form} phx-change="validate" phx-submit="save">
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

        <%!-- Same /auth/:provider flow as login: find_or_create_from_oauth/1
              registers the account when it doesn't exist yet. Hidden while
              signup is gated — AuthController enforces it server-side too. --%>
        <.oauth_providers :if={@gate == :ok} label={gettext("or sign up with")} />

        <p :if={@gate == :ok} class="text-sm text-gray-400 text-center mt-4">
          <%= gettext("Already have an account?") %> <.link href="/login" class="text-blue-400 hover:text-blue-300"><%= gettext("Log in") %></.link>
        </p>
      </.card>
    </div>
    """
  end
end
