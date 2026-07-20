defmodule Colloq.Workers.MentionTriggerWorker do
  @moduledoc """
  @username mention processing worker.

  Triggered on post creation. Parses the body for @mentions.
  For each mention found:
  - Creates a notification for the mentioned user.
  - Enqueues LlmResponderWorker if the mentioned user is a bot persona.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Accounts
  alias Colloq.Forum
  alias Colloq.Notifications

  @mention_regex ~r/@([a-zA-Z0-9_]{3,30})/

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Forum.get_post!(post_id)

    mentions = extract_mentions(post.body)

    for username <- mentions, username != post.user.username do
      handle_mention(username, post)
    end

    :ok
  end

  @doc """
  Extrae los nombres de usuario mencionados en el texto.
  """
  def extract_mentions(body) when is_binary(body) do
    @mention_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp handle_mention(username, post) do
    case Accounts.get_user_by_username(username) do
      nil ->
        :ok

      mentioned_user ->
        notify_mention(mentioned_user, post)
        maybe_trigger_bot(mentioned_user, post)
    end
  end

  # "Silenciado" promises the user is never notified about the topic, so a
  # mention inside a muted topic must stay silent too. Self-mentions are
  # dropped for the same reason a self-reply isn't a notification.
  defp notify_mention(%{id: id}, %{user_id: id}), do: :ok

  defp notify_mention(mentioned_user, post) do
    if Colloq.Subscriptions.get_level(mentioned_user.id, post.topic_id) == "muted" do
      :ok
    else
      do_notify_mention(mentioned_user, post)
    end
  end

  defp do_notify_mention(mentioned_user, post) do
    Notifications.create_notification(%{
      user_id: mentioned_user.id,
      type: "mention",
      title: "#{post.user.username} te mencionó",
      body: "Te mencionaron en «#{post.topic.title}»",
      data: %{
        post_id: post.id,
        topic_id: post.topic_id,
        actor_id: post.user_id,
        actor_username: post.user.username
      }
    })
  end

  defp maybe_trigger_bot(mentioned_user, post) do
    bot =
      Repo.get_by(Colloq.Bots.BotSystem,
        slug: mentioned_user.username,
        type: "persona",
        active: true
      )

    if bot do
      %{post_id: post.id, persona_slug: bot.slug}
      |> Colloq.Workers.LlmResponderWorker.new()
      |> Oban.insert()
    end
  end
end
