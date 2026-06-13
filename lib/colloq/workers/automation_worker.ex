defmodule Colloq.Workers.AutomationWorker do
  @moduledoc """
  Worker despachador genérico de reglas de automatización.

  Carga la regla de automatización por ID, evalúa la configuración
  del trigger y ejecuta el script asociado.

  Triggers soportados: recurring, user_registered, user_promoted,
  post_created, stalled_topic, point_in_time, api_call.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Automations
  alias Colloq.Automations.Automation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"automation_id" => automation_id, "trigger" => trigger} = args}) do
    automation = Repo.get!(Automation, automation_id)

    unless automation.enabled do
      {:discard, "automatización deshabilitada"}
    else
      trigger_data = Map.get(args, "trigger_data", %{})

      if evaluate_trigger(trigger, automation.trigger_config, trigger_data) do
        Automations.run_automation(automation)
      else
        {:discard, "condición de trigger no cumplida"}
      end
    end
  end

  defp evaluate_trigger("recurring", config, _data) do
    true
  end

  defp evaluate_trigger("user_registered", _config, %{"user_id" => user_id}) do
    user = Colloq.Accounts.get_user!(user_id)
    check_conditions(user)
  end

  defp evaluate_trigger("user_promoted", config, %{"user_id" => user_id, "new_level" => level}) do
    min_level = Map.get(config, "min_level", 1)
    level >= min_level
  end

  defp evaluate_trigger("post_created", config, %{"post_id" => post_id}) do
    post = Colloq.Forum.get_post!(post_id)
    min_length = Map.get(config, "min_body_length", 0)

    if min_length > 0 do
      String.length(post.body || "") >= min_length
    else
      true
    end
  end

  defp evaluate_trigger("stalled_topic", config, %{"topic_id" => topic_id}) do
    topic = Colloq.Forum.get_topic!(topic_id)
    stale_days = Map.get(config, "stale_days", 30)
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days, :day)

    not is_nil(topic.bumped_at) and DateTime.compare(topic.bumped_at, cutoff) == :lt
  end

  defp evaluate_trigger("point_in_time", config, _data) do
    cron_expr = Map.get(config, "cron", "* * * * *")
    true
  end

  defp evaluate_trigger("api_call", _config, _data) do
    true
  end

  defp check_conditions(_user), do: true
end
