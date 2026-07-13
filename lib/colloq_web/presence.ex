defmodule ColloqWeb.Presence do
  @moduledoc """
  Tracks which users are currently connected (online) via their LiveView
  sockets, on the global `"online_users"` topic.

  Used to show a green "connected" indicator on avatars.
  """
  use Phoenix.Presence,
    otp_app: :colloq,
    pubsub_server: Colloq.PubSub

  @topic "online_users"

  @doc "Track the given user as online for the calling LiveView process."
  def track_user(pid, user_id) do
    track(pid, @topic, to_string(user_id), %{online_at: System.system_time(:second)})
  end

  @doc "Is the user currently connected?"
  def online?(user_id) do
    case get_by_key(@topic, to_string(user_id)) do
      [] -> false
      %{metas: []} -> false
      _ -> true
    end
  end

  @doc "Set of user ids (strings) currently online."
  def online_ids do
    @topic |> list() |> Map.keys() |> MapSet.new()
  end
end
