defmodule Colloq.Automations do
  @moduledoc """
  Automation rule engine for Colloq.

  Allows creating rules that react to forum events (triggers)
  and execute scripts (actions). Each script lives under
  Colloq.Automations.Scripts.*.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Automations.Automation

  @doc """
  Lists all automation rules.
  """
  def list_automations do
    Automation
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Creates a new automation rule.

  Receives a map or keyword list with:
  - name: descriptive name
  - trigger: trigger type
  - trigger_config: trigger configuration
  - script: name of the script to execute
  - script_config: script configuration
  - enabled: boolean (default true)
  """
  def create_automation(attrs) do
    %Automation{}
    |> Automation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing rule.
  """
  def update_automation(%Automation{} = automation, attrs) do
    automation
    |> Automation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an automation rule.
  """
  def delete_automation(%Automation{} = automation) do
    Repo.delete(automation)
  end

  @doc """
  Runs the script of an automation rule.

  Dispatches to the corresponding script module based on the script field.
  Updates last_run_at upon completion.
  """
  def run_automation(%Automation{} = automation) do
    result = dispatch_script(automation.script, automation.script_config)

    automation
    |> Ecto.Changeset.change(last_run_at: DateTime.utc_now())
    |> Repo.update!()

    result
  end

  # --- Script dispatch ---

  defp dispatch_script("send_pm", config), do: Colloq.Automations.Scripts.send_pm(config)
  defp dispatch_script("create_post", config), do: Colloq.Automations.Scripts.create_post(config)
  defp dispatch_script("llm_respond", config), do: Colloq.Automations.Scripts.llm_respond(config)
  defp dispatch_script("close_topic", config), do: Colloq.Automations.Scripts.close_topic(config)
  defp dispatch_script("pin_topic", config), do: Colloq.Automations.Scripts.pin_topic(config)
  defp dispatch_script("flag_post", config), do: Colloq.Automations.Scripts.flag_post(config)
  defp dispatch_script("auto_tag", config), do: Colloq.Automations.Scripts.auto_tag(config)
  defp dispatch_script(unknown, _config), do: {:error, "unsupported script: #{unknown}"}
end

defmodule Colloq.Automations.Scripts do
  @moduledoc """
  Invocable automation scripts.

  Each function receives a serialized configuration map from
  the script_config field of the automations table.
  """

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Accounts
  alias Colloq.Messaging
  alias Colloq.Moderation

  @doc """
  Sends a private message to a user from the system.
  Config: %{to_user_id, title, body}
  """
  def send_pm(%{"to_user_id" => to_user_id, "title" => title, "body" => body} = config) do
    system_user_id = Map.get(config, "from_user_id", find_system_user_id())
    {:ok, conv} = Messaging.find_or_create_conversation(system_user_id, to_user_id)
    system_user = Accounts.get_user!(system_user_id)
    Messaging.send_message(conv.id, system_user, "#{title}\n\n#{body}")
  end

  def send_pm(_), do: {:error, "invalid configuration for send_pm"}

  @doc """
  Creates a post in a topic as a specific user (typically a bot).
  Config: %{topic_id, user_id, body}
  """
  def create_post(%{"topic_id" => topic_id, "user_id" => user_id, "body" => body}) do
    topic = Forum.get_topic!(topic_id)
    user = Accounts.get_user!(user_id)
    Forum.create_post(topic, user, %{"body" => body})
  end

  def create_post(_), do: {:error, "invalid configuration for create_post"}

  @doc """
  Triggers an LLM response from a bot persona.
  Config: %{post_id, persona_slug}
  """
  def llm_respond(%{"post_id" => post_id, "persona_slug" => persona_slug}) do
    %{post_id: post_id, persona_slug: persona_slug}
    |> Colloq.Workers.LlmResponderWorker.new()
    |> Oban.insert()
  end

  def llm_respond(_), do: {:error, "invalid configuration for llm_respond"}

  @doc """
  Closes a topic with a reason.
  Config: %{topic_id, reason}
  """
  def close_topic(%{"topic_id" => topic_id, "reason" => reason}) do
    topic = Forum.get_topic!(topic_id)
    Forum.close_topic(topic, reason)
  end

  def close_topic(_), do: {:error, "invalid configuration for close_topic"}

  @doc """
  Pins a topic.
  Config: %{topic_id}
  """
  def pin_topic(%{"topic_id" => topic_id}) do
    topic = Forum.get_topic!(topic_id)

    topic
    |> Ecto.Changeset.change(pinned: true, pinned_at: DateTime.utc_now())
    |> Repo.update()
  end

  def pin_topic(_), do: {:error, "invalid configuration for pin_topic"}

  @doc """
  Flags a post automatically.
  Config: %{post_id, reason}
  """
  def flag_post(%{"post_id" => post_id, "reason" => reason}) do
    system_user_id = find_system_user_id()
    Moderation.flag_post(post_id, system_user_id, reason)
  end

  def flag_post(_), do: {:error, "invalid configuration for flag_post"}

  @doc """
  Applies automatic tags to a topic based on keywords in the title.
  Config: %{topic_id, tags}
  """
  def auto_tag(%{"topic_id" => _topic_id, "tags" => _tags} = config) do
    # Tags are stored in an intermediate topic_tags table or as an array in topics
    # This implementation leaves the hook ready for when that table is defined.
    {:ok, "auto_tag ejecutado: #{inspect(config)}"}
  end

  def auto_tag(_), do: {:error, "invalid configuration for auto_tag"}

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
