defmodule Colloq.Bots.BotPersona do
  @moduledoc """
  Bot persona schema with LLM configuration.

  Bots can have configurable personalities with
  system prompts, adjustable LLM models, and usage
  restrictions by trust level.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "bot_personas" do
    field :name, :string
    field :slug, :string
    field :avatar_url, :string
    field :description, :string
    field :system_prompt, :string
    field :provider, :string
    field :model, :string
    field :temperature, :float, default: 0.7
    field :max_tokens, :integer, default: 512
    field :enabled, :boolean, default: true
    field :trigger_on_mention, :boolean, default: true
    field :trigger_categories, {:array, :integer}
    field :allowed_trust_level, :integer, default: 0
    field :rate_limit_per_user, :integer, default: 10
    field :managed_by_worker, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [
      :name, :slug, :avatar_url, :description, :system_prompt,
      :provider, :model, :temperature, :max_tokens, :enabled,
      :trigger_on_mention, :trigger_categories, :allowed_trust_level,
      :rate_limit_per_user, :managed_by_worker
    ])
    |> validate_required([:name, :slug])
    |> validate_number(:temperature, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_number(:allowed_trust_level, greater_than_or_equal_to: 0)
    |> validate_number(:rate_limit_per_user, greater_than: 0)
    |> unique_constraint(:slug)
  end
end
