defmodule Colloq.Forum.Tag do
  @moduledoc """
  Tag for categorizing topics beyond the category system.

  Tags are user-selectable labels like "transferencias", "lesiones",
  "táctica", etc. that help filter and discover content.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :color, :string, default: "#6b7280"
    field :topic_count, :integer, default: 0

    many_to_many :topics, Colloq.Forum.Topic, join_through: "topic_tags"

    # A synonym points at the tag it defers to; the canonical tag lists them.
    belongs_to :synonym_of, __MODULE__
    has_many :synonyms, __MODULE__, foreign_key: :synonym_of_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :slug, :description, :color, :synonym_of_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 40)
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> validate_not_self_synonym()
    |> generate_slug()
  end

  # A tag pointing at itself would make resolution loop forever.
  defp validate_not_self_synonym(changeset) do
    id = get_field(changeset, :id)
    target = get_field(changeset, :synonym_of_id)

    if id && target && id == target do
      add_error(changeset, :synonym_of_id, "a tag cannot be a synonym of itself")
    else
      changeset
    end
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end
      _ ->
        changeset
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end
end
