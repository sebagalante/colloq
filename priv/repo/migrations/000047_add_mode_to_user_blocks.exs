defmodule Colloq.Repo.Migrations.AddModeToUserBlocks do
  use Ecto.Migration

  def change do
    alter table(:user_blocks) do
      # "ignore" = one-directional (you stop seeing them);
      # "block"  = mutual (neither sees the other).
      add :mode, :string, null: false, default: "block"
    end
  end
end
