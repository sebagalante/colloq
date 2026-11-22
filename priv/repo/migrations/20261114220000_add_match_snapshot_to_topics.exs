defmodule Colloq.Repo.Migrations.AddMatchSnapshotToTopics do
  use Ecto.Migration

  # Last score the banner showed, so a match thread keeps its banner after the
  # live sources stop answering for it (old fixture, API blip, FotMob window).
  def change do
    alter table(:topics) do
      add :match_snapshot, :map
    end
  end
end
