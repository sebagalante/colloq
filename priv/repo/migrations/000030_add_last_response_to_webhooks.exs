defmodule Colloq.Repo.Migrations.AddLastResponseToWebhooks do
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      add_if_not_exists :last_response, :text
    end
  end
end
