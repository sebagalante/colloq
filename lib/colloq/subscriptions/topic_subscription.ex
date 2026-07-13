defmodule Colloq.Subscriptions.TopicSubscription do
  @moduledoc "A user's per-topic notification level."
  use Ecto.Schema
  import Ecto.Changeset

  @levels ~w(watching tracking normal muted)

  schema "topic_subscriptions" do
    field :level, :string, default: "normal"
    belongs_to :user, Colloq.Accounts.User
    belongs_to :topic, Colloq.Forum.Topic

    timestamps(type: :utc_datetime_usec)
  end

  def levels, do: @levels

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:user_id, :topic_id, :level])
    |> validate_required([:user_id, :topic_id, :level])
    |> validate_inclusion(:level, @levels)
    |> unique_constraint([:user_id, :topic_id])
  end
end
