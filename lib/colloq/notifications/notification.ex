defmodule Colloq.Notifications.Notification do
  @moduledoc """
  Notification schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "notifications" do
    field :type, :string
    # "mention", "reply", "reaction", "trust_promotion", "system"

    field :title, :string
    field :body, :string
    field :data, :map, default: %{}  # Flexible: %{post_id, topic_id, actor_id, emoji}

    field :read, :boolean, default: false
    field :read_at, :utc_datetime_usec
    field :email_sent, :boolean, default: false
    field :email_sent_at, :utc_datetime_usec

    # NULL = in the inbox. Set = archived (kept, but hidden from the inbox and
    # excluded from the unread badge).
    field :archived_at, :utc_datetime_usec

    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :type, :title, :body, :data, :user_id,
      :read, :read_at, :email_sent, :email_sent_at, :archived_at
    ])
    |> validate_required([:type, :title, :user_id])
    |> validate_inclusion(:type, ~w(mention reply reaction trust_promotion system match_event warning))
  end
end
