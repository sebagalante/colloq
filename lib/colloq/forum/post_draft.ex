defmodule Colloq.Forum.PostDraft do
  @moduledoc """
  An unsent composer body, kept per user per topic.

  `topic_id` nil means a draft of a *new topic* (where `title` and `category_id`
  carry the rest of the form); a set `topic_id` is a reply draft.

  `Colloq.Workers.PruneDraftsWorker` deletes drafts once they go stale.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_drafts" do
    field :title, :string
    field :body, :string

    belongs_to :user, Colloq.Accounts.User
    belongs_to :topic, Colloq.Forum.Topic
    belongs_to :category, Colloq.Forum.Category

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:user_id, :topic_id, :category_id, :title, :body])
    |> validate_required([:user_id])
    # Partial unique indexes (see the migration): one reply draft per topic,
    # one new-topic draft. Named so a lost race surfaces as a changeset error
    # rather than a raised constraint, which save_draft/3 retries.
    |> unique_constraint([:user_id, :topic_id], name: :post_drafts_user_topic_index)
    |> unique_constraint(:user_id, name: :post_drafts_user_new_topic_index)
  end
end
