defmodule Colloq.Repo.Migrations.FlairSystemBots do
  use Ecto.Migration

  # Persona bots already carry the "BOT" flair; the older system bots were
  # created before Accounts.register_bot/1 existed and have no flair, so they
  # leaked onto the leaderboard. Stamp them here. New bots are flaired at
  # creation.
  @system_bots ~w(sofascorebot scorebot dolarbot gifbot)

  def up do
    list = Enum.map_join(@system_bots, ",", &"'#{&1}'")
    execute("UPDATE users SET flair = 'BOT' WHERE username IN (#{list}) AND (flair IS NULL OR flair <> 'BOT')")
  end

  def down do
    list = Enum.map_join(@system_bots, ",", &"'#{&1}'")
    execute("UPDATE users SET flair = NULL WHERE username IN (#{list}) AND flair = 'BOT'")
  end
end
