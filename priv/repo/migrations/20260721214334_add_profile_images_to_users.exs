defmodule Colloq.Repo.Migrations.AddProfileImagesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Wide banner across the top of the public profile.
      add :profile_header_url, :string
      # Backdrop for the hover user card.
      add :card_background_url, :string
    end
  end
end
