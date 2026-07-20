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

    # Last-activity timestamp (used for "recent topics" ordering)
    field :bumped_at, :utc_datetime_usec

    # States
    field :pinned, :boolean, default: false
    field :pinned_at, :utc_datetime_usec
    field :closed, :boolean, default: false
    field :closed_at, :utc_datetime_usec
    field :closed_reason, :string
    # Set when this topic was auto-closed as a re-post; the banner links to it.
    belongs_to :duplicate_of, Colloq.Forum.Topic
    field :archived, :boolean, default: false
    field :archived_at, :utc_datetime_usec
    # Announcement mode: staff can post, regular users read only.
    field :staff_only, :boolean, default: false

    # Soft delete (Discourse-style): a deleted topic is hidden from regular
    # users but recoverable by staff until a later purge. See Forum.delete_topic/2.
    field :deleted_at, :utc_datetime_usec

    # Match day specific
    field :is_match_thread, :boolean, default: false
    field :match_mode, :string  # "prematch" | "live" | "fulltime"
    field :match_id, :string    # External API fixture ID
    field :home_team, :string
    field :away_team, :string

    # Continuation chain (for 50k+ post threads)
    field :continuation_topic_id, :integer
    field :parent_topic_id, :integer

    # AI summary (persisted so it survives restarts and can be marked outdated
    # when new posts arrive — see summary_post_number).
    field :summary, :string
    field :summary_model, :string
    field :summary_generated_at, :utc_datetime_usec
    field :summary_post_number, :integer

    # Relationships
    belongs_to :user, Colloq.Accounts.User
    belongs_to :deleted_by, Colloq.Accounts.User
    belongs_to :category, Colloq.Forum.Category
    belongs_to :first_post, Colloq.Forum.Post
    belongs_to :last_post, Colloq.Forum.Post

    has_many :posts, Colloq.Forum.Post, foreign_key: :topic_id
    many_to_many :tags, Colloq.Forum.Tag, join_through: "topic_tags", on_replace: :delete

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(topic, attrs) do
    topic
    |> cast(attrs, [
      :title, :slug, :user_id, :category_id, :bumped_at,
      :is_match_thread, :match_id, :match_mode,
      :home_team, :away_team,
      :pinned, :pinned_at, :closed, :closed_reason, :duplicate_of_id,
      :archived, :staff_only, :continuation_topic_id, :parent_topic_id
    ])
    |> validate_required([:title, :user_id, :category_id])
    |> validate_length(:title, min: 5, max: 200)
    |> generate_slug()
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
