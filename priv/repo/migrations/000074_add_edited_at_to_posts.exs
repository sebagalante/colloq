defmodule Colloq.Repo.Migrations.AddEditedAtToPosts do
  use Ecto.Migration

  @moduledoc """
  Records when a post's body was actually edited.

  `updated_at` can't carry this: it also moves when a post is hidden, restored
  or soft-deleted (all changeset writes), so 119 of 612 posts already look
  "edited" without anyone having touched the text. `edited_at` is set only by
  `Forum.update_post/2`, and only when the body really changed.

  NULL = never edited, which is the correct state for every existing row: we
  can't reconstruct which past updates were genuine edits, and guessing would
  put a pen on posts nobody edited.
  """

  def change do
    alter table(:posts) do
      add :edited_at, :utc_datetime_usec
    end
  end
end
