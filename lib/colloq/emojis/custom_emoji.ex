defmodule Colloq.Emojis.CustomEmoji do
  @moduledoc """
  A custom emoji uploaded by an admin. Referenced in text as `:name:` and
  usable both inside posts and as reactions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "custom_emojis" do
    field :name, :string
    field :image_url, :string

    belongs_to :created_by, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [:name, :image_url, :created_by_id])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name, :image_url])
    |> validate_format(:name, ~r/^[a-z0-9_]+$/,
      message: "only lowercase letters, numbers and underscores"
    )
    |> validate_length(:name, min: 2, max: 30)
    |> unique_constraint(:name)
  end

  defp normalize_name(nil), do: nil

  defp normalize_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.trim(":")
  end
end
