defmodule Colloq.Reactions.Reaction do
  @moduledoc """
  Schema de reacción (emoji) de un usuario a un post.

  Cada combinación [post_id, user_id, emoji] debe ser única.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "reactions" do
    field :emoji, :string

    belongs_to :post, Colloq.Forum.Post
    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:emoji, :post_id, :user_id])
    |> validate_required([:emoji, :post_id, :user_id])
    |> validate_length(:emoji, max: 10)
    |> unique_constraint([:post_id, :user_id, :emoji],
      name: :reactions_post_id_user_id_emoji_index,
      message: "ya reaccionaste con este emoji"
    )
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_id)
  end
end
