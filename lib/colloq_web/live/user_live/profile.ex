defmodule ColloqWeb.UserLive.Profile do
  use ColloqWeb, :live_view

  alias Colloq.Accounts
  alias Colloq.Forum
  alias Colloq.Reactions

  @impl true
  def mount(%{"username" => username}, session, socket) do
    current_user = load_user(session)
    user = Accounts.get_user_by_username(username)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:profile_user, user)
      |> assign(:posts, [])
      |> assign(:post_reactions, %{})
      |> assign_new(:page_title, fn ->
        "@#{user && user.username || username}"
      end)

    if user && connected?(socket) do
      posts = list_recent_posts(user.id)
      reactions = load_reactions(posts)

      socket =
        socket
        |> assign(:posts, posts)
        |> assign(:post_reactions, reactions)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp load_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> Accounts.get_user!(user_id)
    end
  end

  defp list_recent_posts(user_id) do
    import Ecto.Query

    Colloq.Forum.Post
    |> where(user_id: ^user_id)
    |> where([p], is_nil(p.deleted_at))
    |> order_by(desc: :inserted_at)
    |> limit(20)
    |> preload(:topic)
    |> Colloq.Repo.all()
  end

  defp load_reactions(posts) do
    for post <- posts, into: %{} do
      {post.id, Reactions.reaction_counts(post.id)}
    end
  end

  def initials(user) do
    name = user.display_name || user.username
    String.slice(name, 0..0) |> String.upcase()
  end

  def trust_level_badge_color(level) do
    case level do
      0 -> "gray"
      1 -> "blue"
      2 -> "green"
      3 -> "purple"
      4 -> "amber"
      _ -> "gray"
    end
  end

  def member_since(user) do
    Calendar.strftime(user.inserted_at, "%d/%m/%Y")
  end

  @doc """
  Plain-text excerpt of a post body for previews.

  Bodies are stored as untrusted HTML, so we strip all markup (rather than
  rendering it raw) and truncate to a short preview. Escaping is handled by
  the default HEEx `<%= %>` interpolation in the template.
  """
  def body_excerpt(nil, _length), do: ""

  def body_excerpt(body, length) when is_binary(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.slice(0, length)
  end
end
