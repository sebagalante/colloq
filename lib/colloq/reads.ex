defmodule Colloq.Reads do
  @moduledoc """
  Per-user, per-topic read tracking. Remembers the highest post_number a user
  has seen so a return visit can jump to where they left off ("next unread").
  Absence of a row means the user has never opened the topic.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Reads.TopicRead

  @doc "Highest post_number the user has read in a topic (0 if never visited)."
  def last_read(nil, _topic_id), do: 0

  def last_read(user_id, topic_id) do
    Repo.one(
      from r in TopicRead,
        where: r.user_id == ^user_id and r.topic_id == ^topic_id,
        select: r.last_read_post_number
    ) || 0
  end

  @doc """
  Record that the user has read up to `post_number` in a topic. Never moves the
  marker backwards, so out-of-order updates (e.g. an old tab) can't lose the
  reader's place. Upserts on the (user_id, topic_id) unique index.
  """
  def mark_read(nil, _topic_id, _post_number), do: :ok

  def mark_read(user_id, topic_id, post_number) when is_integer(post_number) do
    now = DateTime.utc_now()

    Repo.insert_all(
      TopicRead,
      [
        %{
          user_id: user_id,
          topic_id: topic_id,
          last_read_post_number: post_number,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict:
        from(r in TopicRead,
          update: [
            set: [
              last_read_post_number:
                fragment("GREATEST(?, ?)", r.last_read_post_number, ^post_number),
              updated_at: ^now
            ]
          ]
        ),
      conflict_target: [:user_id, :topic_id]
    )

    :ok
  end
end
