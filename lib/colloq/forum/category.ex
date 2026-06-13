defmodule Colloq.Forum.Category do
  @moduledoc """
  Forum category schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :color, :string, default: "#3b82f6"  # Hex color for UI
    field :icon, :string  # Emoji or Lucide icon name
    field :position, :integer, default: 0
    field :topic_count, :integer, default: 0
    field :post_count, :integer, default: 0

    field :read_restricted, :boolean, default: false
    field :write_restricted, :boolean, default: false
    field :required_trust_level, :integer, default: 0

    has_many :topics, Colloq.Forum.Topic

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [
      :name, :slug, :description, :color, :icon, :position,
      :read_restricted, :write_restricted, :required_trust_level
    ])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 60)
    |> unique_constraint(:slug)
  end
end
