defmodule Colloq.Accounts.UserBlock do
  @moduledoc """
  Schema for user-to-user blocks.

  When user A blocks user B:
  - A won't see B's posts, topics, or reactions
  - B won't get notifications from A
  - B can't send DMs to A
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Colloq.Accounts.User

  schema "user_blocks" do
    field :mode, :string, default: "block"
    belongs_to :blocker, User
    belongs_to :blocked, User
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(block, attrs) do
    block
    |> cast(attrs, [:blocker_id, :blocked_id, :mode])
    |> validate_required([:blocker_id, :blocked_id])
    |> validate_inclusion(:mode, ["ignore", "block"])
    |> validate_different_users()
    |> unique_constraint([:blocker_id, :blocked_id],
      name: :user_blocks_blocker_id_blocked_id_index,
      message: "ya bloqueaste a este usuario"
    )
  end

  defp validate_different_users(changeset) do
    validate_change(changeset, :blocked_id, fn _, blocked_id ->
      if get_field(changeset, :blocker_id) == blocked_id do
        [blocked_id: "no podés bloquearte a vos mismo"]
      else
        []
      end
    end)
  end
end
