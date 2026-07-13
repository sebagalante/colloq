defmodule ColloqWeb.UserSocket do
  use Phoenix.Socket

  alias Colloq.Accounts

  @moduledoc """
  Authenticated channel socket.

  Clients connect with a session token generated on login.
  The token is passed as a parameter in the WebSocket connection.

  Channels:
  - `forum:topic:*` — ForumChannel
  - `dm:*` — DmChannel
  - `notifications:*` — NotificationChannel
  """

  channel "forum:topic:*", ColloqWeb.ForumChannel
  channel "dm:*", ColloqWeb.DmChannel
  channel "notifications:*", ColloqWeb.NotificationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_token(token) do
      {:ok, user_id} ->
        user = Accounts.get_user(user_id)

        if user do
          socket =
            socket
            |> assign(:user_id, user_id)
            |> assign(:current_user, user)

          {:ok, socket}
        else
          :error
        end

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"

  defp verify_token(token) do
    salt = Application.get_env(:colloq, :socket_signing_salt, "user_socket")

    case Phoenix.Token.verify(ColloqWeb.Endpoint, salt, token, max_age: 86400) do
      {:ok, user_id} -> {:ok, user_id}
      _ -> :error
    end
  end

  @doc """
  Generates a temporary token for socket connection.
  Used when logging in to pass the token to the client.
  """
  def generate_token(user_id) do
    salt = Application.get_env(:colloq, :socket_signing_salt, "user_socket")
    Phoenix.Token.sign(ColloqWeb.Endpoint, salt, user_id)
  end
end
