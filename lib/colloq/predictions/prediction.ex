defmodule Colloq.Predictions.Prediction do
  @moduledoc """
  Esquema de predicción de partido.

  Un usuario predice el resultado de un fixture (partido).
  Cada [user_id, fixture_id] es único: un usuario solo puede
  predecir una vez por partido.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "predictions" do
    field :fixture_id, :string
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
      :fixture_id, :home_score, :away_score, :first_scorer, :motm,
      :points, :scored_at, :user_id
    ])
    |> validate_required([:fixture_id, :home_score, :away_score, :user_id])
    |> validate_number(:home_score, greater_than_or_equal_to: 0)
    |> validate_number(:away_score, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :fixture_id],
         name: :predictions_user_id_fixture_id_index)
  end
end
