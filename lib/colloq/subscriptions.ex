defmodule Colloq.Subscriptions do
  @moduledoc """
  Per-topic notification levels (Discourse-style): watching / tracking /
  normal / muted. Absence of a row means "normal".
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Subscriptions.TopicSubscription

  @default "normal"

  @doc "The user's notification level for a topic (defaults to \"normal\")."
  def get_level(nil, _topic_id), do: @default

  def get_level(user_id, topic_id) do
    Repo.one(
      from s in TopicSubscription,
        where: s.user_id == ^user_id and s.topic_id == ^topic_id,
        select: s.level
    ) || @default
  end

  @doc "Set (upsert) the user's notification level for a topic."
  def set_level(user_id, topic_id, level) do
    attrs = %{user_id: user_id, topic_id: topic_id, level: level}

    case Repo.get_by(TopicSubscription, user_id: user_id, topic_id: topic_id) do
      nil -> %TopicSubscription{} |> TopicSubscription.changeset(attrs) |> Repo.insert()
      sub -> sub |> TopicSubscription.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Set the level to `watching` only if the user has no explicit level yet
  (used when someone creates a topic or replies — Discourse auto-watch).
  """
  def watch_if_new(user_id, topic_id), do: set_if_new(user_id, topic_id, "watching")

  @doc """
  Set the level to `tracking` only if the user has no explicit level yet.

  What replying to a topic should do. Tracking marks the topic as followed
  without subscribing the person to every subsequent reply — they still get
  notified when someone answers *them* or mentions them, which is what a
  replier actually expects. Matches Discourse's
  `default_other_notification_level_when_replying`, which also defaults to
  Tracking.
  """
  def track_if_new(user_id, topic_id), do: set_if_new(user_id, topic_id, "tracking")

  # Never overwrites a level the user chose for themselves.
  defp set_if_new(user_id, topic_id, level) do
    unless Repo.exists?(
             from s in TopicSubscription,
               where: s.user_id == ^user_id and s.topic_id == ^topic_id
           ) do
      set_level(user_id, topic_id, level)
    end

    :ok
  end

  @doc "User ids watching the given topic (every reply)."
  def topic_watcher_ids(topic_id) do
    Repo.all(
      from s in TopicSubscription,
        where: s.topic_id == ^topic_id and s.level == "watching",
        select: s.user_id
    )
  end

  @doc "User ids who muted the given topic."
  def topic_muter_ids(topic_id) do
    Repo.all(
      from s in TopicSubscription,
        where: s.topic_id == ^topic_id and s.level == "muted",
        select: s.user_id
    )
    |> MapSet.new()
  end

  @doc "Topic ids the user has muted (hidden from Latest)."
  def muted_topic_ids(nil), do: MapSet.new()

  def muted_topic_ids(user_id) do
    Repo.all(
      from s in TopicSubscription,
        where: s.user_id == ^user_id and s.level == "muted",
        select: s.topic_id
    )
    |> MapSet.new()
  end
end
