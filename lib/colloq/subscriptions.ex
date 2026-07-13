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
  def watch_if_new(user_id, topic_id) do
    unless Repo.exists?(
             from s in TopicSubscription,
               where: s.user_id == ^user_id and s.topic_id == ^topic_id
           ) do
      set_level(user_id, topic_id, "watching")
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
