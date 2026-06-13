defmodule ColloqWeb.ForumLive.Topic do
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Accounts
  alias Colloq.Reactions

  @typing_timeout 5_000

  @impl true
  def mount(%{"id" => id}, session, socket) do
    topic = Forum.get_topic!(id)
    current_user = load_user(session)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:topic, topic)
      |> assign(:posts, topic.posts)
      |> assign(:reaction_data, %{})
      |> assign(:typing_users, [])
      |> assign(:reply_body, "")
      |> assign(:match_mode, topic.match_mode)
      |> assign_new(:page_title, fn -> topic.title end)

    if connected?(socket) do
      ColloqWeb.Endpoint.subscribe("forum:topic:#{topic.id}")

      load_reaction_data(topic.posts, socket)

      if current_user do
        broadcast_typing(current_user, false)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"slug" => _slug} = _params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("reply", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    topic = socket.assigns.topic

    if user && !topic.closed && !topic.archived do
      case Forum.create_post(topic, user, %{"body" => body}) do
        {:ok, post} ->
          post = Forum.get_post!(post.id)
          posts = socket.assigns.posts ++ [post]

          {:noreply,
           socket
           |> assign(:posts, posts)
           |> assign(:reply_body, "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "No se pudo publicar la respuesta.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No podés responder en este tema.")}
    end
  end

  def handle_event("reaction", %{"post_id" => post_id_str, "emoji" => emoji}, socket) do
    user = socket.assigns.current_user

    if user do
      post_id = String.to_integer(post_id_str)
      Reactions.toggle_reaction(post_id, user.id, emoji)
    end

    {:noreply, socket}
  end

  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user

    if user do
      broadcast_typing(user, true)
    end

    {:noreply, socket}
  end

  def handle_event("stopped_typing", _params, socket) do
    user = socket.assigns.current_user

    if user do
      broadcast_typing(user, false)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "new_post", payload: payload}, socket) do
    post = Forum.get_post!(payload.post_id)
    posts = socket.assigns.posts ++ [post]

    {:noreply,
     socket
     |> assign(:posts, posts)
     |> assign(:reaction_data, Map.put(socket.assigns.reaction_data, post.id, %{}))}
  end

  def handle_info(%{event: "reaction_updated", payload: %{post_id: post_id, counts: counts}}, socket) do
    {:noreply,
     socket
     |> assign(:reaction_data, Map.put(socket.assigns.reaction_data, post_id, counts))}
  end

  def handle_info(%{event: "match_event", payload: payload}, socket) do
    post = Forum.get_post!(payload.post_id)
    posts = socket.assigns.posts ++ [post]

    {:noreply, assign(socket, :posts, posts)}
  end

  def handle_info(%{event: "match_mode_changed", payload: %{mode: mode}}, socket) do
    {:noreply, assign(socket, :match_mode, mode)}
  end

  def handle_info(%{event: "user_typing", payload: %{user_id: user_id, username: username}}, socket) do
    typing = socket.assigns.typing_users |> List.keydelete(user_id, 0) |> List.keystore(user_id, 0, {user_id, username})

    Process.send_after(self(), {:typing_timeout, user_id}, @typing_timeout)

    {:noreply, assign(socket, :typing_users, typing)}
  end

  def handle_info(%{event: "user_stopped_typing", payload: %{user_id: user_id}}, socket) do
    typing = List.keydelete(socket.assigns.typing_users, user_id, 0)
    {:noreply, assign(socket, :typing_users, typing)}
  end

  def handle_info({:typing_timeout, user_id}, socket) do
    typing = List.keydelete(socket.assigns.typing_users, user_id, 0)
    {:noreply, assign(socket, :typing_users, typing)}
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  defp load_reaction_data(posts, socket) do
    reaction_data =
      for post <- posts, into: %{} do
        {post.id, Reactions.reaction_counts(post.id)}
      end

    assign(socket, :reaction_data, reaction_data)
  end

  defp broadcast_typing(user, is_typing) do
    event = if is_typing, do: "user_typing", else: "user_stopped_typing"

    ColloqWeb.Endpoint.broadcast_from(self(), "forum:topic:#{user.id}",
      event, %{user_id: user.id, username: user.username})
  end

  def can_reply?(assigns) do
    assigns.current_user && !assigns.topic.closed && !assigns.topic.archived
  end

  @doc """
  Sanitize a stored post body before rendering it as raw HTML.

  Post bodies are stored as HTML (rendered from Tiptap JSON) and come from
  untrusted sources — forum users and LLM bots — so they must be sanitized
  on the way out to prevent stored XSS. Strips scripts, event handlers and
  other dangerous markup while keeping basic formatting.
  """
  def render_body(nil), do: Phoenix.HTML.raw("")

  def render_body(body) when is_binary(body) do
    body
    |> HtmlSanitizeEx.basic_html()
    |> Phoenix.HTML.raw()
  end

  def initials(user) do
    name = user.display_name || user.username
    String.slice(name, 0..0) |> String.upcase()
  end

  def avatar_class(user) do
    colors = %{
      blue: "bg-blue-600",
      green: "bg-green-600",
      red: "bg-red-600",
      amber: "bg-amber-600",
      purple: "bg-purple-600"
    }

    idx = :erlang.phash2(user.id, map_size(colors))
    colors |> Map.values() |> Enum.at(idx)
  end

  def trust_badge_color(level) do
    case level do
      0 -> "gray"
      1 -> "blue"
      2 -> "green"
      3 -> "purple"
      4 -> "amber"
      _ -> "gray"
    end
  end

  def typing_text(users) when users == [], do: ""

  def typing_text(users) do
    names = Enum.map(users, fn {_id, username} -> username end)

    case names do
      [name] -> "#{name} está escribiendo..."
      [first, second] -> "#{first} y #{second} están escribiendo..."
      [first, second | _rest] -> "#{first}, #{second} y otros están escribiendo..."
    end
  end
end
