defmodule Colloq.Trust do
  @moduledoc """
  Trust level context — manages Discourse-model trust levels (TL0–TL4).
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Trust.TrustLevel

  def get_level(level) when is_integer(level) do
    Repo.get_by(TrustLevel, level: level)
  end

  def list_levels do
    TrustLevel
    |> order_by(:level)
    |> Repo.all()
  end

  def can_create_topics?(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> false
      tl -> tl.can_create_topics
    end
  end

  def can_send_pms?(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> false
      tl -> tl.can_send_pms
    end
  end

  def daily_post_limit(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> 0
      tl ->
        cond do
          tl.daily_post_limit == 0 -> :unlimited
          true -> tl.daily_post_limit
        end
    end
  end
end