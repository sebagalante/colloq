defmodule Colloq.Reactions.Reaction do
  @moduledoc """
  User emoji reaction schema for posts.

  One reaction per `[post_id, user_id]`: a user reacts to a post once, and
  choosing a different emoji replaces their previous choice rather than adding
  to it. Users may not react to their own posts.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ColloqWeb.Gettext

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
    # Up to 32 to allow custom-emoji shortcodes (":name:"), not just unicode.
    |> validate_length(:emoji, max: 32)
    |> unique_constraint([:post_id, :user_id],
      name: :reactions_post_id_user_id_index,
      message: gettext("already reacted to this post")
    )
    |> foreign_key_constraint(:post_id)
    |> foreign_key_constraint(:user_id)
  end
end
