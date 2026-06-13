defmodule Colloq.Bots.BotSystem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "bot_system" do
    field :name, :string
    field :slug, :string
    field :type, :string
    field :active, :boolean, default: true
    field :api_key, :string
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(bot, attrs) do
    bot
    |> cast(attrs, [:name, :slug, :type, :active, :api_key, :config])
    |> validate_required([:name, :slug, :type])
    |> validate_inclusion(:type, ~w(system persona))
    |> unique_constraint(:slug)
  end
end