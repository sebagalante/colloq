defmodule Colloq.Predictions.Prediction do
  @moduledoc """
  Match prediction schema.

  A user predicts the outcome of a fixture (match).
  Each [user_id, fixture_id] is unique: a user can only
  predict once per match.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "predictions" do
    field :fixture_id, :string
    field :season_id, :integer
    field :round, :integer
    field :home_score, :integer
    field :away_score, :integer
    field :first_scorer, :string
    field :motm, :string

    field :points, :integer, default: 0
    field :scored_at, :utc_datetime_usec

    belongs_to :user, Colloq.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [
      :fixture_id, :season_id, :round, :home_score, :away_score, :first_scorer, :motm,
      :points, :scored_at, :user_id
    ])
    |> validate_required([:fixture_id, :home_score, :away_score, :user_id])
    |> validate_number(:home_score, greater_than_or_equal_to: 0)
    |> validate_number(:away_score, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :fixture_id],
         name: :predictions_user_id_fixture_id_index)
  end
end
