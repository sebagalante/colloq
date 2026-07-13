defmodule Colloq.Trust do
  @moduledoc """
  Trust level context — manages trust levels (TL0–TL4) adapted from
  Discourse for a football forum with higher daily limits.
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

  def can_edit_posts?(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> false
      tl -> tl.can_edit_posts
    end
  end

  def can_upload_images?(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> false
      tl -> tl.can_upload_images
    end
  end

  def can_flag_posts?(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> false
      tl -> tl.can_flag_posts
    end
  end

  @doc """
  Returns the daily post limit for a trust level.
  Returns :unlimited if the limit is 0.
  """
  def daily_post_limit(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> 0
      tl ->
        if tl.daily_post_limit == 0, do: :unlimited, else: tl.daily_post_limit
    end
  end

  @doc """
  Returns the daily reaction limit for a trust level.
  Returns :unlimited if the limit is 0.
  """
  def daily_reaction_limit(trust_level) when is_integer(trust_level) do
    case get_level(trust_level) do
      nil -> 0
      tl ->
        if tl.daily_reaction_limit == 0, do: :unlimited, else: tl.daily_reaction_limit
    end
  end
end
