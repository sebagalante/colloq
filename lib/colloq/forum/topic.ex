defmodule Colloq.Forum.Topic do
  @moduledoc """
  Topic (thread) schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "topics" do
    field :title, :string
    field :slug, :string
    field :raw_title, :string  # Pre-slugify title for search

    # Counters
    field :posts_count, :integer, default: 0
    field :views_count, :integer, default: 0
    field :likes_count, :integer, default: 0  # Legacy, replaced by reactions

    # States
    field :pinned, :boolean, default: false
    field :pinned_at, :utc_datetime_usec
    field :closed, :boolean, default: false
    field :closed_at, :utc_datetime_usec
    field :closed_reason, :string
    field :archived, :boolean, default: false
    field :archived_at, :utc_datetime_usec

    # Match day specific
    field :is_match_thread, :boolean, default: false
    field :match_mode, :string  # "prematch" | "live" | "fulltime"
    field :match_id, :string    # External API fixture ID

    # Continuation chain (for 50k+ post threads)
    field :continuation_topic_id, :integer
    field :parent_topic_id, :integer

    # Relationships
    belongs_to :user, Colloq.Accounts.User
    belongs_to :category, Colloq.Forum.Category
    belongs_to :first_post, Colloq.Forum.Post
    belongs_to :last_post, Colloq.Forum.Post

    has_many :posts, Colloq.Forum.Post, foreign_key: :topic_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [
      :title, :slug, :user_id, :category_id,
      :is_match_thread, :match_id, :match_mode,
      :pinned, :pinned_at, :closed, :closed_reason,
      :archived, :continuation_topic_id, :parent_topic_id
    ])
    |> validate_required([:title, :user_id, :category_id])
    |> validate_length(:title, min: 5, max: 200)
    |> generate_slug()
    |> unique_constraint(:slug)
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :title) do
      nil -> changeset
      title -> put_change(changeset, :slug, slugify(title))
    end
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> String.slice(0, 100)
  end
end
