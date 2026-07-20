defmodule Colloq.Automations.Automation do
  @moduledoc """
  Automation rule schema.

  Each rule has a trigger (event that fires it), trigger configuration,
  a script to execute, and its configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import ColloqWeb.Gettext

  @valid_triggers ~w(recurring user_registered user_promoted post_created stalled_topic point_in_time api_call)
  @valid_scripts ~w(send_pm create_post llm_respond close_topic pin_topic flag_post auto_tag recompute_scores)

  schema "automations" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :trigger, :string
    field :trigger_config, :map, default: %{}
    field :script, :string
    field :script_config, :map, default: %{}
    field :last_run_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(automation, attrs) do
    automation
    |> cast(attrs, [
      :name, :enabled, :trigger, :trigger_config,
      :script, :script_config, :last_run_at
    ])
    |> validate_required([:name, :trigger, :script])
    |> validate_length(:name, min: 3, max: 100)
    |> validate_inclusion(:trigger, @valid_triggers,
      message: gettext("invalid trigger. Valid: %{triggers}", triggers: Enum.join(@valid_triggers, ", "))
    )
    |> validate_inclusion(:script, @valid_scripts,
      message: gettext("invalid script. Valid: %{scripts}", scripts: Enum.join(@valid_scripts, ", "))
    )
  end
end
