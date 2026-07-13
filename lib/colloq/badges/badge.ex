defmodule Colloq.Badges.Badge do
  @moduledoc """
  Admin-created badge that can be granted to users.

  Badges are displayed next to usernames in posts and profiles.
  Users can display up to 3 badges at a time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "badges" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :icon, :string, default: "🏅"
    field :color, :string, default: "#3b82f6"
    field :position, :integer, default: 0

    has_many :user_badges, Colloq.Badges.UserBadge

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [:name, :slug, :description, :icon, :color, :position])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 50)
    |> validate_length(:slug, max: 50)
    |> validate_length(:icon, max: 10)
    |> validate_format(:slug, ~r/^[a-z0-9_-]+$/, message: "only lowercase letters, numbers, hyphens and underscores")
    |> unique_constraint(:slug)
    |> generate_slug()
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
    |> String.slice(0, 50)
  end
end
