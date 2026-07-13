defmodule Colloq.Badges do
  @moduledoc """
  Badges context: admin-created badges for users.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Badges.{Badge, UserBadge}

  # --- Badge CRUD (admin only) ---

  @doc """
  Lists all badges ordered by position.
  """
  def list_badges do
    Badge
    |> order_by(:position)
    |> Repo.all()
  end

  @doc """
  Gets a badge by ID.
  """
  def get_badge!(id), do: Repo.get!(Badge, id)

  @doc """
  Creates a badge.
  """
  def create_badge(attrs) do
    %Badge{}
    |> Badge.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a badge.
  """
  def update_badge(%Badge{} = badge, attrs) do
    badge
    |> Badge.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a badge. Revokes it from all users first.
  """
  def delete_badge(%Badge{} = badge) do
    Repo.transaction(fn ->
      from(ub in UserBadge, where: ub.badge_id == ^badge.id)
      |> Repo.delete_all()

      Repo.delete!(badge)
    end)
  end

  # --- User Badge Management ---

  @doc """
  Grants a badge to a user.
  """
  def grant_badge(user_id, badge_id, granted_by_id \\ nil) do
    # Find next available display position
    existing_count =
      from(ub in UserBadge, where: ub.user_id == ^user_id)
      |> Repo.aggregate(:count)

    position = if existing_count < 3, do: existing_count, else: -1

    %UserBadge{}
    |> UserBadge.changeset(%{
      user_id: user_id,
      badge_id: badge_id,
      granted_by_id: granted_by_id,
      display_position: position
    })
    |> Repo.insert()
  end

  @doc """
  Revokes a badge from a user.
  """
  def revoke_badge(user_id, badge_id) do
    case Repo.get_by(UserBadge, user_id: user_id, badge_id: badge_id) do
      nil -> {:error, :not_found}
      user_badge -> Repo.delete(user_badge)
    end
  end

  @doc """
  Updates the display position of a user's badge.
  """
  def update_badge_position(%UserBadge{} = user_badge, position) do
    user_badge
    |> Ecto.Changeset.change(display_position: position)
    |> Repo.update()
  end

  @doc """
  Gets all badges for a user, preloaded with badge data.
  """
  def get_user_badges(user_id) do
    from(ub in UserBadge,
      where: ub.user_id == ^user_id,
      join: b in assoc(ub, :badge),
      order_by: [asc: ub.display_position],
      preload: [badge: b]
    )
    |> Repo.all()
  end

  @doc """
  Gets the top 3 displayed badges for a user.
  """
  def get_user_display_badges(user_id) do
    from(ub in UserBadge,
      where: ub.user_id == ^user_id,
      join: b in assoc(ub, :badge),
      order_by: [asc: ub.display_position],
      limit: 3,
      preload: [badge: b]
    )
    |> Repo.all()
  end

  @doc """
  Gets display badges for multiple users in a single query.
  Returns a map of user_id => list of %{icon, color, name}.
  """
  def preload_display_badges(user_ids) do
    badges_by_user =
      from(ub in UserBadge,
        where: ub.user_id in ^user_ids,
        join: b in assoc(ub, :badge),
        order_by: [asc: ub.display_position],
        preload: [badge: b]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.user_id)

    Map.new(badges_by_user, fn {user_id, user_badges} ->
      displayed =
        user_badges
        |> Enum.take(3)
        |> Enum.map(fn ub ->
          %{icon: ub.badge.icon, color: ub.badge.color, name: ub.badge.name}
        end)

      {user_id, displayed}
    end)
  end

  @doc """
  Returns a list of user_ids that have been granted a specific badge.
  """
  def users_with_badge(badge_id) do
    from(ub in UserBadge, where: ub.badge_id == ^badge_id, select: ub.user_id)
    |> Repo.all()
  end
end
