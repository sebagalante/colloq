defmodule Colloq.Bookmarks.Bookmark do
  @moduledoc """
  User bookmark for a post.

  A user can bookmark any post to find it later.
  Each [user_id, post_id] combination is unique.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "bookmarks" do
    field :note, :string

    belongs_to :user, Colloq.Accounts.User
    belongs_to :post, Colloq.Forum.Post
    belongs_to :topic, Colloq.Forum.Topic

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:user_id, :post_id, :topic_id, :note])
    |> validate_required([:user_id, :post_id])
    |> validate_length(:note, max: 500)
    |> unique_constraint([:user_id, :post_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:post_id)
  end
end
