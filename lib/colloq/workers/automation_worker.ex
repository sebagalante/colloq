defmodule Colloq.Workers.AutomationWorker do
  @moduledoc """
  Generic automation rule dispatcher worker.

  Loads the automation rule by ID, evaluates the trigger configuration,
  and executes the associated script.

  Supported triggers: recurring, user_registered, user_promoted,
  post_created, stalled_topic, point_in_time, api_call.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Automations
  alias Colloq.Automations.Automation

  @default_interval_minutes 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"automation_id" => automation_id, "trigger" => trigger} = args}) do
    automation = Repo.get!(Automation, automation_id)

    unless automation.enabled do
      {:discard, "automatización deshabilitada"}
    else
      trigger_data = Map.get(args, "trigger_data", %{})

      if evaluate_trigger(trigger, automation.trigger_config, trigger_data, automation) do
        Automations.run_automation(automation)
      else
        {:discard, "condición de trigger no cumplida"}
      end
    end
  end

  # The scheduler already spaces these out with Oban uniqueness, but that only
  # holds while the completed job is still in the table — once it's pruned, a
  # tick can enqueue again inside the interval. `last_run_at` is the durable
  # check, so a 6-hourly automation can't fire twice in an hour after a prune.
  defp evaluate_trigger("recurring", config, _data, automation) do
    minutes = interval_minutes(config)

    case automation.last_run_at do
      nil ->
        true

      last_run_at ->
        DateTime.diff(DateTime.utc_now(), last_run_at, :second) >= minutes * 60
    end
  end

  defp evaluate_trigger("user_registered", _config, %{"user_id" => user_id}, _automation) do
    user = Colloq.Accounts.get_user!(user_id)
    check_conditions(user)
  end

  defp evaluate_trigger("user_promoted", config, %{"new_level" => level}, _automation) do
    min_level = Map.get(config, "min_level", 1)
    level >= min_level
  end

  defp evaluate_trigger("post_created", config, %{"post_id" => post_id}, _automation) do
    post = Colloq.Forum.get_post!(post_id)
    min_length = Map.get(config, "min_body_length", 0)

    if min_length > 0 do
      String.length(post.body || "") >= min_length
    else
      true
    end
  end

  defp evaluate_trigger("stalled_topic", config, %{"topic_id" => topic_id}, _automation) do
    topic = Colloq.Forum.get_topic!(topic_id)
    stale_days = Map.get(config, "stale_days", 30)
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days, :day)

    not is_nil(topic.bumped_at) and DateTime.compare(topic.bumped_at, cutoff) == :lt
  end

  # Fires only on the minutes its cron expression names (UTC). The scheduler
  # ticks every minute and enqueues these unconditionally, so this is where the
  # expression is actually honoured — before, any "point in time" automation ran
  # on every tick regardless of its cron. An unparseable expression never fires,
  # rather than firing constantly.
  defp evaluate_trigger("point_in_time", config, _data, _automation) do
    expr = Map.get(config, "cron", "* * * * *")

    case Oban.Cron.Expression.parse(expr) do
      {:ok, cron} -> Oban.Cron.Expression.now?(cron)
      {:error, _} -> false
    end
  end

  defp evaluate_trigger("api_call", _config, _data, _automation) do
    true
  end

  defp interval_minutes(config) do
    case Map.get(config || %{}, "interval_minutes") do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> @default_interval_minutes
        end

      _ ->
        @default_interval_minutes
    end
  end

  defp check_conditions(_user), do: true
end
