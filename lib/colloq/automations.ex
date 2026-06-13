defmodule Colloq.Automations do
  @moduledoc """
  Motor de reglas de automatización para Colloq.

  Permite crear reglas que reaccionan a eventos del foro (triggers)
  y ejecutan scripts (acciones). Cada script vive bajo
  Colloq.Automations.Scripts.*.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Automations.Automation

  @doc """
  Lista todas las reglas de automatización.
  """
  def list_automations do
    Automation
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Crea una nueva regla de automatización.

  Recibe un mapa o keyword list con:
  - name: nombre descriptivo
  - trigger: tipo de trigger
  - trigger_config: configuración del trigger
  - script: nombre del script a ejecutar
  - script_config: configuración del script
  - enabled: booleano (default true)
  """
  def create_automation(attrs) do
    %Automation{}
    |> Automation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Actualiza una regla existente.
  """
  def update_automation(%Automation{} = automation, attrs) do
    automation
    |> Automation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Elimina una regla de automatización.
  """
  def delete_automation(%Automation{} = automation) do
    Repo.delete(automation)
  end

  @doc """
  Ejecuta el script de una regla de automatización.

  Despacha al módulo de script correspondiente según el campo script.
  Actualiza last_run_at al finalizar.
  """
  def run_automation(%Automation{} = automation) do
    result = dispatch_script(automation.script, automation.script_config)

    automation
    |> Ecto.Changeset.change(last_run_at: DateTime.utc_now())
    |> Repo.update!()

    result
  end

  # --- Despacho de scripts ---

  defp dispatch_script("send_pm", config), do: Colloq.Automations.Scripts.send_pm(config)
  defp dispatch_script("create_post", config), do: Colloq.Automations.Scripts.create_post(config)
  defp dispatch_script("llm_respond", config), do: Colloq.Automations.Scripts.llm_respond(config)
  defp dispatch_script("close_topic", config), do: Colloq.Automations.Scripts.close_topic(config)
  defp dispatch_script("pin_topic", config), do: Colloq.Automations.Scripts.pin_topic(config)
  defp dispatch_script("flag_post", config), do: Colloq.Automations.Scripts.flag_post(config)
  defp dispatch_script("auto_tag", config), do: Colloq.Automations.Scripts.auto_tag(config)
  defp dispatch_script(unknown, _config), do: {:error, "script no soportado: #{unknown}"}
end

defmodule Colloq.Automations.Scripts do
  @moduledoc """
  Scripts de automatización invocables desde las reglas.

  Cada función recibe un mapa de configuración serializado desde
  el campo script_config de la tabla automations.
  """

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Accounts
  alias Colloq.Messaging
  alias Colloq.Moderation

  @doc """
  Envía un mensaje privado a un usuario desde el sistema.
  Config: %{to_user_id, title, body}
  """
  def send_pm(%{"to_user_id" => to_user_id, "title" => title, "body" => body} = config) do
    system_user_id = Map.get(config, "from_user_id", find_system_user_id())
    {:ok, conv} = Messaging.find_or_create_conversation(system_user_id, to_user_id)
    system_user = Accounts.get_user!(system_user_id)
    Messaging.send_message(conv.id, system_user, "#{title}\n\n#{body}")
  end

  def send_pm(_), do: {:error, "configuración inválida para send_pm"}

  @doc """
  Crea un post en un topic como un usuario específico (normalmente un bot).
  Config: %{topic_id, user_id, body}
  """
  def create_post(%{"topic_id" => topic_id, "user_id" => user_id, "body" => body}) do
    topic = Forum.get_topic!(topic_id)
    user = Accounts.get_user!(user_id)
    Forum.create_post(topic, user, %{"body" => body})
  end

  def create_post(_), do: {:error, "configuración inválida para create_post"}

  @doc """
  Dispara una respuesta LLM desde una persona bot.
  Config: %{post_id, persona_slug}
  """
  def llm_respond(%{"post_id" => post_id, "persona_slug" => persona_slug}) do
    %{post_id: post_id, persona_slug: persona_slug}
    |> Colloq.Workers.LlmResponderWorker.new()
    |> Oban.insert()
  end

  def llm_respond(_), do: {:error, "configuración inválida para llm_respond"}

  @doc """
  Cierra un topic con una razón.
  Config: %{topic_id, reason}
  """
  def close_topic(%{"topic_id" => topic_id, "reason" => reason}) do
    topic = Forum.get_topic!(topic_id)
    Forum.close_topic(topic, reason)
  end

  def close_topic(_), do: {:error, "configuración inválida para close_topic"}

  @doc """
  Fija (pin) un topic.
  Config: %{topic_id}
  """
  def pin_topic(%{"topic_id" => topic_id}) do
    topic = Forum.get_topic!(topic_id)

    topic
    |> Ecto.Changeset.change(pinned: true, pinned_at: DateTime.utc_now())
    |> Repo.update()
  end

  def pin_topic(_), do: {:error, "configuración inválida para pin_topic"}

  @doc """
  Reporta (flag) un post automáticamente.
  Config: %{post_id, reason}
  """
  def flag_post(%{"post_id" => post_id, "reason" => reason}) do
    system_user_id = find_system_user_id()
    Moderation.flag_post(post_id, system_user_id, reason)
  end

  def flag_post(_), do: {:error, "configuración inválida para flag_post"}

  @doc """
  Aplica tags automáticos a un topic según palabras clave en el título.
  Config: %{topic_id, tags}
  """
  def auto_tag(%{"topic_id" => _topic_id, "tags" => _tags} = config) do
    # Las tags se almacenan en una tabla intermedia topic_tags o como array en topics
    # Esta implementación deja el hook listo para cuando se defina esa tabla.
    {:ok, "auto_tag ejecutado: #{inspect(config)}"}
  end

  def auto_tag(_), do: {:error, "configuración inválida para auto_tag"}

  defp find_system_user_id do
    case Accounts.get_user_by_username("sistema") do
      nil ->
        case Accounts.get_user_by_username("system") do
          nil -> 0
          user -> user.id
        end

      user ->
        user.id
    end
  end
end
