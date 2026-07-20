defmodule Colloq.Repo.Migrations.AddHiddenFlagToPosts do
  use Ecto.Migration

  @moduledoc """
  Distinguishes a moderator/system *hide* from a user deleting their own post.

  Both set `deleted_at`, which made the moderation "Hidden posts" queue show
  every self-deletion. `hidden: true` now marks only staff/system removals;
  `deleted_by_id` records who did it. Existing soft-deleted posts default to
  `hidden: false` (treated as self-deletions), which matches the data — none of
  them are linked to any flag.
  """
  def change do
    alter table(:posts) do
      add :hidden, :boolean, default: false, null: false
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
    end

    # The moderation queue filters on this flag.
    create index(:posts, [:hidden])
  end
end
