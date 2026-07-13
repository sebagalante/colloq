defmodule Colloq.Forum.VoiceRoom do
  @moduledoc """
  Voice room schema associated with topics.

  Voice rooms allow users to have real-time voice conversations
  within a forum topic. They can be ephemeral (removed when ended)
  or permanent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "voice_rooms" do
    field :name, :string
    field :slug, :string
    field :trust_level_required, :integer, default: 0
    field :max_participants, :integer, default: 10
    field :ephemeral, :boolean, default: false

    belongs_to :topic, Colloq.Forum.Topic
    belongs_to :created_by, Colloq.Accounts.User, foreign_key: :created_by_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :slug, :topic_id, :trust_level_required,
                     :max_participants, :created_by_id, :ephemeral])
    |> validate_required([:name, :slug])
    |> validate_number(:trust_level_required, greater_than_or_equal_to: 0)
    |> validate_number(:max_participants, greater_than: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:slug)
  end
end
