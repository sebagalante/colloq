defmodule Colloq.Gamification do
  @moduledoc """
  Community engagement scoring ("puntos").

  Points reward being active and supportive: posting, starting topics, giving
  and receiving likes, and visiting (reading topics). Scores are denormalised
  onto `users.score` and recomputed on a schedule by the "Recompute scores"
  automation (script `recompute_scores`), so the leaderboard is a cheap
  ordered read.

  Weights are intentionally simple integers so the score is easy to reason
  about and tune. Receiving a like is worth more than giving one (it signals
  the community valued what you wrote); starting a topic is worth more than a
  reply; visiting counts a little so lurking-but-present readers still climb.
  """

  import Ecto.Query

  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Forum.{Post, Topic}
  alias Colloq.Reactions.Reaction
  alias Colloq.Reads.TopicRead

  # Points per signal. Change these to retune the ladder.
  @w_post 2
  @w_topic 5
  @w_like_received 3
  @w_like_given 1
  @w_topic_read 1

  @doc "The scoring weights, for display/explainers."
  def weights do
    %{
      post: @w_post,
      topic: @w_topic,
      like_received: @w_like_received,
      like_given: @w_like_given,
      topic_read: @w_topic_read
    }
  end

  @doc """
  Recomputes every user's score from their current activity and writes it to
  `users.score`. Returns the number of users updated.

  A handful of grouped aggregate queries pull each signal as a
  `user_id => count` map; the scores are combined in memory and written back.
  Cheap enough to run every few minutes on a forum-sized user base.
  """
  def recompute_all do
    topics = count_by_user(Topic)
    likes_given = count_by_user(Reaction)
    likes_received = likes_received_by_user()
    reads = count_by_user(TopicRead)
    now = DateTime.utc_now()

    # posts_count is already maintained on the user row (excludes deleted), so
    # we reuse it rather than re-counting the posts table.
    users = Repo.all(from(u in User, select: {u.id, u.posts_count}))

    Enum.each(users, fn {id, posts_count} ->
      score = score_for(id, posts_count, topics, likes_received, likes_given, reads)

      from(u in User, where: u.id == ^id)
      |> Repo.update_all(set: [score: score, score_updated_at: now])
    end)

    length(users)
  end

  @doc """
  The point breakdown for one user: a list of `{label, count, points}` plus the
  total. Handy for a profile card or a leaderboard tooltip.
  """
  def breakdown(%User{id: id, posts_count: posts_count}) do
    topics = Map.get(count_by_user(Topic), id, 0)
    given = Map.get(count_by_user(Reaction), id, 0)
    received = Map.get(likes_received_by_user(), id, 0)
    reads = Map.get(count_by_user(TopicRead), id, 0)
    posts = posts_count || 0

    rows = [
      {:post, posts, posts * @w_post},
      {:topic, topics, topics * @w_topic},
      {:like_received, received, received * @w_like_received},
      {:like_given, given, given * @w_like_given},
      {:topic_read, reads, reads * @w_topic_read}
    ]

    %{rows: rows, total: Enum.reduce(rows, 0, fn {_, _, pts}, acc -> acc + pts end)}
  end

  # --- Internals -------------------------------------------------------------

  defp score_for(id, posts_count, topics, received, given, reads) do
    (posts_count || 0) * @w_post +
      Map.get(topics, id, 0) * @w_topic +
      Map.get(received, id, 0) * @w_like_received +
      Map.get(given, id, 0) * @w_like_given +
      Map.get(reads, id, 0) * @w_topic_read
  end

  # `user_id => row count` for any schema that belongs to a user.
  defp count_by_user(schema) do
    Repo.all(
      from(x in schema,
        group_by: x.user_id,
        select: {x.user_id, count(x.id)}
      )
    )
    |> Map.new()
  end

  # Likes received = reactions on a user's (non-deleted) posts, grouped by the
  # post's author.
  defp likes_received_by_user do
    Repo.all(
      from(r in Reaction,
        join: p in Post,
        on: p.id == r.post_id,
        where: is_nil(p.deleted_at),
        group_by: p.user_id,
        select: {p.user_id, count(r.id)}
      )
    )
    |> Map.new()
  end
end
