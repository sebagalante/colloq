defmodule Colloq.Forum.Post do
  @moduledoc """
  Post schema.
  Stores both HTML (body) and Tiptap JSON (body_json) for full fidelity.

  System posts (`is_system: true`) have a `system_type` that controls rendering:
  - "goal" — goal alert from ScoreBotWorker
  - "card" — card alert (yellow/red)
  - "sub" — substitution alert
  - "summary" — match summary
  - "standings" — league standings table
  - "x_feed" — imported tweet from X/Twitter
  - "continuation" / "continuation_start" — thread continuation chain
  - "prediction_results" — prediction scoring results
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :body, :string  # HTML rendered for display
    field :body_json, :map  # Tiptap JSON document
    field :post_number, :integer
    field :deleted_at, :utc_datetime_usec
    # Set only when the body is edited — not by hides, deletes or counter
    # updates, all of which move updated_at.
    field :edited_at, :utc_datetime_usec
    # `hidden` distinguishes a moderator/system removal (shows in the moderation
    # queue) from a user deleting their own post (`deleted_at` set, hidden false).
    field :hidden, :boolean, default: false

    # Counters
    field :view_count, :integer, default: 0
    field :reactions_count, :integer, default: 0

    # Match day: bot posts have special rendering
    field :is_system, :boolean, default: false
    field :system_type, :string  # "goal", "card", "sub", "summary"
    field :event_data, :map  # Goal: %{player, minute, assist, score}, Card: %{player, minute, type}

    # Relationships
    belongs_to :topic, Colloq.Forum.Topic
    belongs_to :user, Colloq.Accounts.User
    belongs_to :deleted_by, Colloq.Accounts.User
    has_one :first_topic, Colloq.Forum.Topic, foreign_key: :first_post_id
    has_one :last_topic, Colloq.Forum.Topic, foreign_key: :last_post_id

    # Nested replies
    belongs_to :parent, Colloq.Forum.Post
    has_many :replies, Colloq.Forum.Post, foreign_key: :parent_id

    # Polls
    has_one :poll, Colloq.Forum.Poll

    # Link unfurls / rich embeds
    has_many :embeds, Colloq.Forum.Embed

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :body, :body_json, :topic_id, :user_id, :post_number,
      :is_system, :system_type, :event_data, :parent_id, :edited_at
    ])
    |> sanitize_body()
    |> validate_required([:body, :topic_id, :user_id, :post_number])
    |> validate_length(:body, max: 50_000)
    |> foreign_key_constraint(:topic_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Create a system/bot post (score event, lineup, etc).
  """
  def system_changeset(attrs) do
    %__MODULE__{is_system: true}
    |> cast(attrs, [
      :body, :body_json, :topic_id, :user_id, :post_number,
      :system_type, :event_data
    ])
    |> sanitize_body()
    |> validate_required([:body, :topic_id, :user_id, :post_number, :system_type])
  end

  # Bodies are stored as HTML (rendered from Tiptap JSON) and originate from
  # untrusted sources — forum users and LLM bots — so we sanitize on write to
  # strip scripts, event handlers and dangerous markup while keeping basic
  # formatting. Render-time sanitization stays as defense in depth.
  #
  # We use the html5 scrubber (the same one render_body uses) rather than
  # basic_html because it preserves the marker attributes rich composer
  # features rely on — `data-spoiler` on inline spoilers and `data-sensitive`
  # on blurred media. basic_html would strip those, flattening the markup back
  # to plain text/images. html5 still removes scripts, `on*` handlers and
  # `javascript:` URLs, so it's no weaker against XSS.
  defp sanitize_body(changeset) do
    update_change(changeset, :body, fn
      nil -> nil
      body -> HtmlSanitizeEx.html5(body)
    end)
  end
end
