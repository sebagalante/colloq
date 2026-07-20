defmodule Colloq.Repo.Migrations.AddSummaryToTopics do
  use Ecto.Migration

  def change do
    alter table(:topics) do
      add :summary, :text
      add :summary_model, :string
      add :summary_generated_at, :utc_datetime_usec
      # posts_count at generation time — drives the "outdated" indicator.
      add :summary_post_number, :integer
    end
  end
end
