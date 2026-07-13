defmodule Colloq.Workers.TopicArchiveWorker do
  @moduledoc """
  Automatic topic archiving worker.

  Runs every 15 minutes.
  - Closes topics exceeding 50,000 posts if not already closed.
  - Archives topics with no activity for more than 90 days.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic
  import Ecto.Query

  @post_limit 50_000
  @archive_days 90

  @impl Oban.Worker
  def perform(_job) do
    close_limit_threads()
    archive_old_threads()
    :ok
  end

  defp close_limit_threads do
    cutoff = DateTime.utc_now()

    Topic
    |> Ecto.Query.where([t], t.posts_count >= @post_limit and t.closed == false)
    |> Repo.all()
    |> Enum.each(fn topic ->
      Forum.close_topic(topic, "post_limit")
    end)
  end

  defp archive_old_threads do
    cutoff = DateTime.utc_now() |> DateTime.add(-@archive_days, :day)

    Topic
    |> Ecto.Query.where([t], t.bumped_at < ^cutoff and t.archived == false and t.closed == true)
    |> Repo.all()
    |> Enum.each(fn topic ->
      Forum.archive_topic(topic)
    end)
  end
end
