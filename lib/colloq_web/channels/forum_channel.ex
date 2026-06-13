defmodule ColloqWeb.ForumChannel do
  use Phoenix.Channel

  def join("forum:topic:" <> topic_id, _payload, socket) do
    {:ok, assign(socket, :topic_id, topic_id)}
  end
end
