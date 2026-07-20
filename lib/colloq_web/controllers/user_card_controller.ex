defmodule ColloqWeb.UserCardController do
  @moduledoc """
  Lightweight JSON payload for the hover "user card" popover.

  The card is shown when the pointer hovers any `/u/:username` link across the
  forum (see `assets/js/user_card.js`). It returns just enough to render the
  card without a full profile page load.
  """
  use ColloqWeb, :controller

  import Ecto.Query

  alias Colloq.Accounts
  alias Colloq.Badges
  alias Colloq.Forum.Post
  alias Colloq.Reactions.Reaction
  alias Colloq.Repo

  def show(conn, %{"username" => username}) do
    case Accounts.get_user_by_username(username) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      user ->
        json(conn, %{user: card_payload(conn, user)})
    end
  end

  defp card_payload(conn, user) do
    current_user = conn.assigns[:current_user]

    %{
      username: user.username,
      display_name: user.display_name || user.username,
      avatar_url: user.avatar_url,
      initials: initials(user),
      location: user.location,
      bio: user.bio,
      flair: user.flair,
      role: user.role,
      profile_path: ~p"/u/#{user.username}",
      online: ColloqWeb.Presence.online?(user.id),
      joined_at: user.inserted_at,
      last_seen_at: user.last_login_at,
      last_post_at: last_post_at(user.id),
      posts_count: user.posts_count || 0,
      cheers: cheers(user.id),
      trust_level: user.trust_level,
      trust_level_name: ColloqWeb.UserLive.Profile.trust_level_name(user.trust_level),
      badges: badges(user.id),
      can_message:
        current_user != nil and current_user.id != user.id and
          Colloq.Messaging.can_message?(current_user, user) == :ok
    }
  end

  defp initials(user) do
    (user.display_name || user.username) |> String.slice(0..0) |> String.upcase()
  end

  defp last_post_at(user_id) do
    Repo.one(
      from p in Post,
        where: p.user_id == ^user_id and is_nil(p.deleted_at),
        order_by: [desc: p.inserted_at],
        limit: 1,
        select: p.inserted_at
    )
  end

  defp cheers(user_id) do
    Repo.one(
      from r in Reaction,
        join: p in Post,
        on: p.id == r.post_id,
        where: p.user_id == ^user_id,
        select: count(r.id)
    ) || 0
  end

  defp badges(user_id) do
    user_id
    |> Badges.get_user_display_badges()
    |> Enum.map(fn ub ->
      %{name: ub.badge.name, icon: ub.badge.icon, color: ub.badge.color}
    end)
  end
end
