defmodule Colloq.Workers.PrunePostsWorker do
  @moduledoc """
  Permanently deletes posts that have been soft-deleted long enough.

  Until this existed nothing ever purged them: every post hidden by moderation
  or removed by its author stayed in `posts` forever, invisible but permanent.

  ## Retention

    * moderation/system hides (`hidden: true`) — #{30} days. These are where
      false positives land, so they get the most generous appeal window: a
      member who was auto-hidden while away still has their post recoverable.
    * author self-deletions (`hidden: false`) — #{7} days. Nobody appeals their
      own deletion; Discourse's default for this is 24 hours.

  ## What is never purged

    * a post with an **unresolved flag** — `flags.post_id` cascades, so deleting
      it would delete the open moderation case with it;
    * a post that still has **replies**. `posts.parent_id` is `SET NULL`, not
      cascade, so removing a parent promotes its children to root-level comments
      — a spam post's replies would resurface as top-level posts in the thread.
      Those parents are left behind deliberately; once the children are purged
      on their own schedule, a later run takes the parent.

  Score history survives: `spam_classifications.post_id` nilifies rather than
  cascading, so the dashboard keeps its distribution after the bodies are gone.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Colloq.Forum.Post
  alias Colloq.Moderation.Flag
  alias Colloq.Repo

  require Logger

  @moderated_retention_days 30
  @self_deleted_retention_days 7

  @doc "Retention windows, for display and tests."
  def retention_days, do: %{moderated: @moderated_retention_days, self_deleted: @self_deleted_retention_days}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    dry_run? = args["dry_run"] == true

    ids = purgeable_ids()

    if dry_run? do
      Logger.info("[PrunePosts] dry run — #{length(ids)} post(s) would be deleted")
      {:ok, %{would_delete: length(ids)}}
    else
      {deleted, _} = Repo.delete_all(from p in Post, where: p.id in ^ids)
      if deleted > 0, do: Logger.info("[PrunePosts] permanently deleted #{deleted} post(s)")
      {:ok, %{deleted: deleted}}
    end
  end

  @doc """
  Ids eligible for permanent deletion right now.

  Public so an admin can see what a run would take before it takes it.
  """
  def purgeable_ids do
    now = DateTime.utc_now()
    moderated_cutoff = DateTime.add(now, -@moderated_retention_days, :day)
    self_cutoff = DateTime.add(now, -@self_deleted_retention_days, :day)

    from(p in Post,
      as: :post,
      where: not is_nil(p.deleted_at),
      where:
        (p.hidden == true and p.deleted_at < ^moderated_cutoff) or
          (p.hidden == false and p.deleted_at < ^self_cutoff),
      # An open flag means an open case; deleting the post deletes the case.
      where:
        not exists(
          from f in Flag, where: f.post_id == parent_as(:post).id and f.resolved == false, select: 1
        ),
      # Children would be promoted to root comments by the SET NULL on
      # parent_id — including replies that are still perfectly visible.
      where:
        not exists(
          from c in Post, where: c.parent_id == parent_as(:post).id, select: 1
        ),
      select: p.id
    )
    |> Repo.all()
  end
end
