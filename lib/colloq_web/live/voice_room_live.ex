defmodule ColloqWeb.VoiceRoomLive do
  @moduledoc """
  LiveView for voice rooms.

  Handles WebRTC signaling relay between peers via PubSub.
  Media stays peer-to-peer (no SFU/MCU) — the server only relays
  SDP offers/answers and ICE candidates between participants.

  PubSub channel: "voice:room:<room_id>"
  Events:
  - "user-joined" — new participant entered
  - "user-left" — participant left
  - "signal" — WebRTC signaling (offer/answer/ICE)
  - "speaking" — VAD status update
  """
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Repo

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
    unless Application.get_env(:colloq, :voice_rooms_enabled, false) do
      {:ok, redirect(socket, to: "/")}
    else
      room = Forum.get_voice_room_by_slug(slug)

      if room do
        current_user = load_user(session)

        socket =
          socket
          |> assign(:current_user, current_user)
          |> assign(:room, room)
          |> assign(:participants, [])
          |> assign(:speaking_users, %{})
          |> assign(:joined, false)

        if connected?(socket) do
          ColloqWeb.Endpoint.subscribe("voice:room:#{room.id}")
        end

        {:ok, socket}
      else
        {:ok,
         socket
         |> put_flash(:error, gettext("Voice room not found."))
         |> redirect(to: "/")}
      end
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # Client -> Server: user is ready to join (mic access granted)
  @impl true
  def handle_event("voice-ready", %{"room_id" => room_id}, socket) do
    user = socket.assigns.current_user

    if user do
      # Broadcast join to other participants
      ColloqWeb.Endpoint.broadcast("voice:room:#{room_id}", "user-joined", %{
        user_id: user.id,
        username: user.username,
        display_name: user.display_name
      })

      {:noreply, assign(socket, :joined, true)}
    else
      {:noreply, push_redirect(socket, to: "/login")}
    end
  end

  # Client -> Server: leave voice room
  def handle_event("voice-leave", %{"room_id" => room_id}, socket) do
    user = socket.assigns.current_user

    if user do
      ColloqWeb.Endpoint.broadcast("voice:room:#{room_id}", "user-left", %{
        user_id: user.id
      })

      {:noreply,
       socket
       |> assign(:joined, false)
       |> assign(:speaking_users, Map.delete(socket.assigns.speaking_users, user.id))}
    else
      {:noreply, socket}
    end
  end

  # Client -> Server: relay a WebRTC signal (SDP offer/answer or ICE candidate)
  # to a specific peer. The server is a dumb relay — it broadcasts the signal
  # on the room channel and lets the receiving client filter by `to` user id.
  def handle_event("voice-signal", %{"to" => to_user_id, "signal" => signal}, socket) do
    user = socket.assigns.current_user
    room = socket.assigns.room

    if user do
      ColloqWeb.Endpoint.broadcast("voice:room:#{room.id}", "signal", %{
        from: user.id,
        to: to_user_id,
        signal: signal
      })
    end

    {:noreply, socket}
  end

  # Client -> Server: VAD speaking status
  def handle_event("voice-speaking", %{"speaking" => speaking}, socket) do
    user = socket.assigns.current_user

    if user do
      ColloqWeb.Endpoint.broadcast("voice:room:#{socket.assigns.room.id}", "speaking", %{
        user_id: user.id,
        speaking: speaking
      })
    end

    {:noreply, socket}
  end

  # Server -> Client (via PubSub): another user joined.
  # Deduplicate by user_id, then push a "voice-peer-joined" event to the
  # local JS hook so it creates a new RTCPeerConnection for the peer.
  # We skip pushing the event to the joiner themselves (they initiate).
  @impl true
  def handle_info(%{event: "user-joined", payload: payload}, socket) do
    participants = socket.assigns.participants

    # Add to participants if not already present
    participants =
      if Enum.any?(participants, &(&1.user_id == payload.user_id)) do
        participants
      else
        [%{user_id: payload.user_id, username: payload.username, display_name: payload.display_name} | participants]
      end

    # Push event to the JS hook (only to other clients, not the joiner)
    socket =
      if socket.assigns.current_user && payload.user_id != socket.assigns.current_user.id do
        push_event(socket, "voice-peer-joined", payload)
      else
        socket
      end

    {:noreply, assign(socket, :participants, participants)}
  end

  # Server -> Client: a participant left — remove from the list, clear
  # their speaking indicator, and notify the JS hook to tear down the
  # peer connection.
  def handle_info(%{event: "user-left", payload: %{user_id: user_id}}, socket) do
    participants = Enum.reject(socket.assigns.participants, &(&1.user_id == user_id))
    speaking_users = Map.delete(socket.assigns.speaking_users, user_id)

    socket = push_event(socket, "voice-peer-left", %{user_id: user_id})

    {:noreply,
     socket
     |> assign(:participants, participants)
     |> assign(:speaking_users, speaking_users)}
  end

  # Server -> Client: relay a WebRTC signal to the intended recipient only.
  # Every client receives every "signal" event on the channel; the guard
  # ensures we only forward to the JS hook when the `to` field matches
  # the current user. This avoids the need for per-user channels.
  def handle_info(%{event: "signal", payload: %{to: to_user_id} = payload}, socket) do
    socket =
      if socket.assigns.current_user && socket.assigns.current_user.id == to_user_id do
        push_event(socket, "voice-signal", payload)
      else
        socket
      end

    {:noreply, socket}
  end

  # Server -> Client: VAD (voice activity detection) speaking status.
  # Tracks which participants are currently speaking so the UI can show
  # an indicator (e.g. a green ring around the avatar).
  def handle_info(%{event: "speaking", payload: %{user_id: user_id, speaking: speaking}}, socket) do
    speaking_users =
      if speaking do
        Map.put(socket.assigns.speaking_users, user_id, true)
      else
        Map.delete(socket.assigns.speaking_users, user_id)
      end

    {:noreply, assign(socket, :speaking_users, speaking_users)}
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Colloq.Accounts.get_user!(user_id)
    end
  end
end
