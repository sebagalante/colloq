defmodule Colloq.Forum.PostLineup do
  @moduledoc """
  A starting XI attached to a post — "the team I'd play".

  Lives in its own table (like `Colloq.Forum.Poll`) rather than inside the post
  body: the body is scrubbed by `HtmlSanitizeEx.html5/1` on render, which strips
  `style` attributes and inline `<svg>`, so a positioned board can't survive
  there. Rendering happens next to the body instead.

  `players` is a frozen snapshot of the chosen XI, so a post keeps showing the
  lineup its author picked even after the squad changes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_lineups" do
    field :team_id, :integer
    field :formation, :string
    field :players, {:array, :map}, default: []

    belongs_to :post, Colloq.Forum.Post

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lineup, attrs) do
    lineup
    |> cast(attrs, [:team_id, :formation, :players, :post_id])
    |> validate_required([:team_id, :formation, :post_id])
    |> validate_formation()
    |> unique_constraint(:post_id)
  end

  defp validate_formation(changeset) do
    validate_change(changeset, :formation, fn :formation, formation ->
      if Colloq.Lineups.valid_formation?(formation),
        do: [],
        else: [formation: "formación inválida"]
    end)
  end
end
