defmodule Colloq.Stickers.Pack do
  @moduledoc """
  A named collection of stickers, shown as a tab in the sticker tray.
  Admin-curated.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sticker_packs" do
    field :name, :string
    field :slug, :string
    field :position, :integer, default: 0

    belongs_to :created_by, Colloq.Accounts.User
    has_many :stickers, Colloq.Stickers.Sticker, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [:name, :slug, :position, :created_by_id])
    |> maybe_slugify()
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9_]+$/,
      message: "only lowercase letters, numbers and underscores"
    )
    |> validate_length(:name, min: 2, max: 40)
    |> unique_constraint(:slug)
  end

  # Derive a slug from the name when none was given.
  defp maybe_slugify(changeset) do
    case get_field(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        put_change(changeset, :slug, normalize(slug))

      _ ->
        case get_field(changeset, :name) do
          name when is_binary(name) -> put_change(changeset, :slug, normalize(name))
          _ -> changeset
        end
    end
  end

  defp normalize(str) do
    str
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
