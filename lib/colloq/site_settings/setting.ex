defmodule Colloq.SiteSettings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "site_settings" do
    field :key, :string
    field :value, :string
    field :type, :string, default: "string"
    field :group, :string, default: "general"
    field :description, :string
    field :public, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :type, :group, :description, :public])
    |> validate_required([:key, :value])
    |> validate_inclusion(:type, ~w(string integer boolean json secret))
    |> unique_constraint(:key)
  end
end