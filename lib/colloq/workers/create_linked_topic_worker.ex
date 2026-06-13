defmodule Colloq.Workers.CreateLinkedTopicWorker do
  @moduledoc """
  Worker de creación de topic de continuación.

  Se encola cuando un topic alcanza 50.000 posts.
  Crea un nuevo topic "Parte N" en la misma categoría,
  enlaza ambos topics como padre/continuación y publica
  un post de sistema en cada uno notificando la transición.
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
    end)

    Logger.info("[CreateLinkedTopic] Parte #{part_number} creada: topic ##{topic_id} -> ##{new_topic.id}")
    :ok
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
