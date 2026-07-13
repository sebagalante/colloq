defmodule Colloq.Forum.Embed do
  @moduledoc """
  URL embed (preview) schema for posts.

  When a user pastes a URL in a post, the system
  extracts metadata (title, description, image) and stores it
  for rich preview rendering.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "embeds" do
    field :url, :string
    field :host, :string
    field :title, :string
    field :description, :string
    field :image_url, :string
    field :author, :string
    field :published_at, :utc_datetime_usec
    field :html, :string
    field :click_count, :integer, default: 0

    belongs_to :post, Colloq.Forum.Post

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(embed, attrs) do
    embed
    |> cast(attrs, [:url, :host, :title, :description, :image_url, :author,
                     :published_at, :html, :post_id])
    |> validate_required([:url, :host])
    |> unique_constraint(:url)
  end

  def click_changeset(embed) do
    embed
    |> change(click_count: embed.click_count + 1)
  end
end
