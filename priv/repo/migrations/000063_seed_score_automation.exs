defmodule Colloq.Repo.Migrations.SeedScoreAutomation do
  use Ecto.Migration

  # Register the leaderboard score recomputation as a managed automation so an
  # admin can enable/disable it and change its interval from the Automations
  # panel, instead of it being an invisible hardcoded cron.
  def up do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    execute("""
    INSERT INTO automations (name, enabled, trigger, trigger_config, script, script_config, inserted_at, updated_at)
    SELECT 'Recompute scores', true, 'recurring', '{"interval_minutes": 5}', 'recompute_scores', '{}', '#{now}', '#{now}'
    WHERE NOT EXISTS (SELECT 1 FROM automations WHERE script = 'recompute_scores')
    """)
  end

  def down do
    execute("DELETE FROM automations WHERE script = 'recompute_scores'")
  end
end
