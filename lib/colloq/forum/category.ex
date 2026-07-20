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

    belongs_to :parent, Colloq.Forum.Category
    has_many :children, Colloq.Forum.Category, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [
      :name, :slug, :description, :color, :icon, :position, :parent_id,
      :read_restricted, :write_restricted, :required_trust_level
    ])
    |> put_slug()
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 60)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: "only lowercase letters, numbers and hyphens"
    )
    |> prevent_self_parent()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:parent_id)
  end

  # Normalise whatever slug arrives, and fall back to the name when the field
  # is left blank. The admin form asks for a slug by hand, which is how
  # categories ended up stored as "El Club" and "Competencias y Partidos" —
  # names copied verbatim, spaces and capitals included, producing URLs like
  # /c/Competencias%20y%20Partidos.
  defp put_slug(changeset) do
    raw = get_field(changeset, :slug)
    name = get_field(changeset, :name)

    case Colloq.Slug.slugify(raw) || Colloq.Slug.slugify(name) do
      nil -> changeset
      slug -> put_change(changeset, :slug, slug)
    end
  end

  # A category can't be its own parent (one level of nesting is enough here).
  defp prevent_self_parent(changeset) do
    id = get_field(changeset, :id)
    parent_id = get_change(changeset, :parent_id)

    if id && parent_id && id == parent_id do
      add_error(changeset, :parent_id, "a category can't be its own parent")
    else
      changeset
    end
  end
end
