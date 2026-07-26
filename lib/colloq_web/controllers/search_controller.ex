defmodule ColloqWeb.SearchController do
  @moduledoc """
  JSON search for the header typeahead.

  A controller rather than a LiveComponent because the header lives in the root
  layout, outside any LiveView — same reason the composer's @mention autocomplete
  goes through `MentionController`.

  Honours the caller's hidden categories, so staff-only areas can't be probed
  through the dropdown.
  """
  use ColloqWeb, :controller

  alias Colloq.Forum

  @min_query 2
  @topic_limit 5
  @post_limit 3
  # Scoped to a single thread there is no topic list competing for space.
  @scoped_post_limit 8
  @excerpt_length 90

  def search(conn, params) do
    query = String.trim(params["q"] || "")
    user = conn.assigns[:current_user]
    topic_id = parse_topic_id(params["topic_id"])

    if String.length(query) < @min_query do
      json(conn, %{topics: [], posts: [], query: query})
    else
      hidden = Forum.hidden_category_ids(user)

      # Scoped to one thread ("in this topic"), matching topics are noise —
      # the reader has already told us which thread they mean, so all the room
      # goes to comments inside it.
      topics =
        if topic_id do
          []
        else
          query
          |> Forum.search_topics(limit: @topic_limit, hidden_category_ids: hidden)
          |> Enum.map(&topic_json/1)
        end

      post_limit = if topic_id, do: @scoped_post_limit, else: @post_limit

      json(conn, %{
        query: query,
        scoped: topic_id != nil,
        topics: topics,
        posts:
          query
          |> Forum.search_posts(
            limit: post_limit,
            hidden_category_ids: hidden,
            topic_id: topic_id
          )
          |> Enum.map(&post_json/1)
      })
    end
  end

  defp parse_topic_id(nil), do: nil

  defp parse_topic_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp topic_json(topic) do
    %{
      title: topic.title,
      url: "/t/#{topic.id}",
      category: topic.category && topic.category.name,
      category_color: topic.category && topic.category.color,
      replies: topic.posts_count
    }
  end

  defp post_json(post) do
    %{
      # `?c=` roots the view at the comment (the same permalink quoting and
      # "Continuar hilo" use). A bare "#post-N" fragment only works when the
      # comment happens to be on the first page, so on a long thread — exactly
      # where search matters — it silently dumped the reader at the top.
      url: "/t/#{post.topic_id}?c=#{post.id}#post-#{post.id}",
      topic: post.topic && post.topic.title,
      author: post.user && post.user.username,
      excerpt: excerpt(post.body)
    }
  end

  defp excerpt(nil), do: ""

  defp excerpt(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @excerpt_length)
  end
end
