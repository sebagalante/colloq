defmodule Colloq.Workers.CreateLinkedTopicWorker do
  @moduledoc """
  Linked topic creation worker.

  Enqueued when a topic reaches 50,000 posts.
  Creates a new "Part N" topic in the same category,
  links both topics as parent/continuation, and posts
  a system post in each announcing the transition.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic
  alias Colloq.Accounts

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "topic_id" => topic_id,
    "category_id" => category_id,
    "part_number" => part_number,
    "user_id" => user_id
  }}) do
    Logger.info("[CreateLinkedTopic] Creando Parte #{part_number} para topic ##{topic_id}")

    old_topic = preloaded_topic!(topic_id)
    system_user = find_system_user()

    result =
      Repo.transaction(fn ->
        {:ok, new_topic} =
          Forum.create_topic(system_user, %{
            "title" => "#{base_title(old_topic.title)} — Parte #{part_number}",
            "category_id" => category_id,
            "parent_topic_id" => old_topic.id
          })

        Forum.close_topic(old_topic, "post_limit")

        old_topic
        |> Ecto.Changeset.change(continuation_topic_id: new_topic.id)
        |> Repo.update!()

        Forum.create_post(old_topic, system_user, %{
          "body" => system_body(old_topic, new_topic),
          "is_system" => true,
          "system_type" => "continuation",
          "event_data" => %{
            continuation_topic_id: new_topic.id,
            part_number: part_number
          }
        })

        Forum.create_post(new_topic, system_user, %{
          "body" => continuation_body(old_topic, part_number),
          "is_system" => true,
          "system_type" => "continuation_start",
          "event_data" => %{
            parent_topic_id: old_topic.id,
            part_number: part_number
          }
        })

        new_topic
      end)

    case result do
      {:ok, new_topic} ->
        Logger.info("[CreateLinkedTopic] Parte #{part_number} creada: topic ##{topic_id} -> ##{new_topic.id}")
        :ok

      {:error, reason} ->
        Logger.error("[CreateLinkedTopic] Error creando parte #{part_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp preloaded_topic!(id) do
    Topic |> Repo.get!(id)
  end

  defp base_title(title) do
    title
    |> String.replace(~r/\s*—\s*Parte\s+\d+$/i, "")
    |> String.trim()
  end

  defp system_body(old_topic, new_topic) do
    """
    <div class="continuation-notice">
      <p>📌 <strong>Este hilo alcanzó los 50.000 posts y fue cerrado automáticamente.</strong></p>
      <p>La conversación continúa en: <a href="/t/#{new_topic.id}">#{new_topic.title}</a></p>
    </div>
    """
  end

  defp continuation_body(old_topic, part_number) do
    """
    <div class="continuation-notice">
      <p>📌 <strong>Este es el hilo de continuación — Parte #{part_number}.</strong></p>
      <p>El hilo anterior fue cerrado por alcanzar el límite de posts.</p>
      <p>Ver hilo anterior: <a href="/t/#{old_topic.id}">#{old_topic.title}</a></p>
    </div>
    """
  end

  defp find_system_user do
    case Accounts.get_user_by_username("sistema") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end

  def new_topic(topic) do
    %{topic_id: topic.id, category_id: topic.category_id}
  end
end
