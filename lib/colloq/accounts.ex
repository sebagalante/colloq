defmodule Colloq.Accounts do
  @moduledoc """
  Accounts context for Colloq.
  
  Handles users, authentication, trust levels, and OAuth identity linking.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Accounts.User
  alias Colloq.Accounts.UserBlock

  @doc """
  Get a user by ID.
  """
  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Records a login: stores the member's IP address and login timestamp.

  `ip` may be an `:inet` tuple (`conn.remote_ip`) or a string. Best-effort —
  never blocks or fails a login.
  """
  def record_login(user_id, ip) do
    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [last_ip: format_ip(ip), last_login_at: DateTime.utc_now()])
  rescue
    _ -> :ok
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end

  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: nil

  @doc """
  Get a user by username.
  """
  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Search users by username or display name prefix, for @mention autocomplete.

  Matches are case-insensitive and prefix-based (username LIKE 'q%'), excluding
  banned users. Returns up to `limit` users ordered by username.
  """
  def search_users_for_mention(query, limit \\ 6) when is_binary(query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      []
    else
      pattern = "#{escape_like(q)}%"

      from(u in User,
        where:
          u.banned == false and
            (ilike(u.username, ^pattern) or ilike(u.display_name, ^pattern)),
        order_by: [asc: u.username],
        limit: ^limit,
        select: %{username: u.username, display_name: u.display_name, avatar_url: u.avatar_url}
      )
      |> Repo.all()
    end
  end

  defp escape_like(str) do
    String.replace(str, ~r/[\\%_]/, fn c -> "\\" <> c end)
  end

  @doc "All non-banned members, most active first (for the members directory)."
  def list_members(limit \\ 200) do
    from(u in User,
      where: u.banned == false,
      order_by: [desc: u.posts_count, asc: u.username],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Top contributors by post count (for the leaderboard)."
  def leaderboard(limit \\ 25) do
    from(u in User,
      # Rank by engagement score (Colloq.Gamification). Every bot account carries
      # the "BOT" flair, which keeps them off the human leaderboard.
      where:
        u.banned == false and (u.score > 0 or u.posts_count > 0) and
          (is_nil(u.flair) or u.flair != "BOT"),
      order_by: [desc: u.score, desc: u.posts_count, desc: u.trust_level],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Get a user by email.
  """
  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Register a new user with email/password.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers an internal bot account. Same as `register_user/1` but stamps the
  "BOT" flair (so bots are excluded from the human leaderboard, from spam
  screening and from trust promotion) and full trust — a system account has
  nothing to earn.
  """
  def register_bot(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    # Full trust — see Colloq.Bots.create_persona_user/2 for the rationale.
    |> Ecto.Changeset.change(%{flair: "BOT", trust_level: 4})
    |> Repo.insert()
  end

  @doc """
  Authenticate by email and password.

  Includes rate limiting: max 5 attempts per email per 15 minutes.
  Returns `{:ok, user}`, `{:error, :invalid_credentials}`, or `{:error, :too_many_attempts}`.
  """
  def authenticate_user(email, password) do
    key = "login_attempts:#{String.downcase(email)}"

    case Cachex.get(:auth_cache, key) do
      {:ok, attempts} when is_integer(attempts) and attempts >= 5 ->
        {:error, :too_many_attempts}

      _ ->
        user = get_user_by_email(email)

        cond do
          user && Bcrypt.verify_pass(password, user.password_hash) ->
            Cachex.del(:auth_cache, key)
            {:ok, user}

          true ->
            Bcrypt.no_user_verify()
            Cachex.incr(:auth_cache, key)
            Cachex.expire(:auth_cache, key, :timer.minutes(15))
            {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Update user settings.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update trust level (called by TrustPromotionWorker).
  """
  def update_trust_level(%User{} = user, new_level) when new_level in 0..4 do
    user
    |> Ecto.Changeset.change(trust_level: new_level)
    |> Repo.update()
  end

  @doc """
  List users eligible for trust level promotion.

  Bots are excluded: they're created at full trust, so a promotion would be a
  no-op that still fires a "¡Subiste de nivel!" notification at them.
  """
  def list_eligible_for_promotion(current_level, min_posts, min_days_since_registration) do
    cutoff = DateTime.utc_now() |> DateTime.add(-min_days_since_registration, :day)

    User
    |> where([u], u.trust_level == ^current_level)
    |> where([u], u.posts_count >= ^min_posts)
    |> where([u], u.inserted_at <= ^cutoff)
    |> where([u], is_nil(u.flair) or u.flair != "BOT")
    |> Repo.all()
  end

  @doc """
  Increment post count for a user.
  """
  def increment_posts_count(%User{} = user) do
    user
    |> Ecto.Changeset.change(posts_count: user.posts_count + 1)
    |> Repo.update()
  end

  @doc """
  OAuth: Find or create user from OAuth data.
  """
  def find_or_create_from_oauth(%{"provider" => provider, "uid" => uid} = attrs) do
    case Repo.get_by(User, oauth_provider: provider, oauth_uid: to_string(uid)) do
      nil ->
        # New OAuth user
        %User{}
        |> User.oauth_changeset(attrs)
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  # =========================================================================
  # User Blocks
  # =========================================================================

  @doc """
  Blocks a user. `mode` is `"ignore"` (one-directional) or `"block"` (mutual).
  If a relationship already exists, its mode is updated.

  Staff (moderators/admins) cannot be *blocked* (mutual invisibility would let
  users evade moderation) — but they may still be *ignored* (one-directional,
  just hides their posts from the ignorer). Blocking staff returns
  `{:error, :cannot_block_staff}`.

  Returns `{:ok, user_block}` or `{:error, changeset | :cannot_block_staff}`.
  """
  def block_user(blocker_id, blocked_id, mode \\ "block") do
    if mode == "block" and staff_user?(blocked_id) do
      {:error, :cannot_block_staff}
    else
      attrs = %{blocker_id: blocker_id, blocked_id: blocked_id, mode: mode}

      case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
        nil -> %UserBlock{} |> UserBlock.changeset(attrs) |> Repo.insert()
        block -> block |> UserBlock.changeset(attrs) |> Repo.update()
      end
    end
  end

  @doc "Whether the given user id belongs to a staff member (mod/admin/super_admin)."
  def staff_user?(user_id) do
    Repo.exists?(from u in User, where: u.id == ^user_id and u.role in ^Colloq.Permissions.roles())
  end

  @doc """
  Unblocks a user. Returns `{:ok, user_block}` or `{:error, :not_found}`.
  """
  def unblock_user(blocker_id, blocked_id) do
    case Repo.get_by(UserBlock, blocker_id: blocker_id, blocked_id: blocked_id) do
      nil -> {:error, :not_found}
      block -> Repo.delete(block)
    end
  end

  @doc """
  Checks if `blocker_id` has blocked `blocked_id`.
  """
  def blocked?(blocker_id, blocked_id) do
    Repo.exists?(from b in UserBlock,
      where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id
    )
  end

  @doc """
  Returns a MapSet of user IDs blocked by `user_id`.
  Used for filtering posts, topics, and notifications.
  """
  def blocked_user_ids(user_id) do
    from(b in UserBlock,
      where: b.blocker_id == ^user_id,
      select: b.blocked_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  User IDs `user_id` has hard-*blocked* (mode `"block"`), excluding one-way
  `"ignore"` relationships.

  Direct messaging is gated on this, not on `blocked_user_ids/1`: "ignore" only
  hides someone's forum posts and must never sever a DM channel (in particular,
  users can only ignore staff, so staff DMs always get through).
  """
  def dm_blocked_user_ids(user_id) do
    from(b in UserBlock,
      where: b.blocker_id == ^user_id and b.mode == "block",
      select: b.blocked_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Whether either user has hard-*blocked* (mode `\"block\"`) the other."
  def dm_blocked?(a_id, b_id) do
    Repo.exists?(
      from b in UserBlock,
        where:
          b.mode == "block" and
            ((b.blocker_id == ^a_id and b.blocked_id == ^b_id) or
               (b.blocker_id == ^b_id and b.blocked_id == ^a_id))
    )
  end

  @doc """
  Users whose posts should be hidden from `user_id`:
  - everyone the user has ignored or blocked (they don't want to see them), and
  - everyone who has *blocked* the user with mode `"block"` (mutual invisibility).

  A one-directional `"ignore"` by someone else does NOT hide the user's own posts
  from them.
  """
  def hidden_user_ids(user_id) do
    from(b in UserBlock,
      where: b.blocker_id == ^user_id or (b.blocked_id == ^user_id and b.mode == "block"),
      select: {b.blocker_id, b.blocked_id}
    )
    |> Repo.all()
    |> Enum.map(fn {blocker, blocked} -> if blocker == user_id, do: blocked, else: blocker end)
    |> MapSet.new()
  end

  @doc """
  Returns a list of %User{} structs blocked by `user_id`.
  For display in settings.
  """
  def list_blocked_users(user_id) do
    from(b in UserBlock,
      where: b.blocker_id == ^user_id,
      join: u in User, on: u.id == b.blocked_id,
      order_by: [desc: b.inserted_at],
      select: u
    )
    |> Repo.all()
  end

  # =========================================================================
  # Two-Factor Authentication (TOTP)
  # =========================================================================

  @doc """
  Generates a new TOTP secret and stores it as pending on the user.

  Returns the raw secret (for QR code generation).
  The secret is NOT yet active — user must verify a code first via `enable_totp/2`.
  """
  def generate_totp_secret(%User{} = user) do
    secret = NimbleTOTP.secret()

    {:ok, user} =
      user
      |> Ecto.Changeset.change(totp_pending_secret: secret)
      |> Repo.update()

    {user, secret}
  end

  @doc """
  Returns the provisioning URI for the TOTP secret (for QR code generation).
  """
  def totp_provisioning_uri(%User{} = user, secret) do
    NimbleTOTP.otpauth_uri("Colloq:#{user.email}", secret)
  end

  @doc """
  Enables TOTP for a user after verifying a code.

  Returns `{:ok, backup_codes}` on success, where backup_codes are plaintext
  strings the user must save. Returns `{:error, :invalid_code}` if the code
  doesn't verify.
  """
  def enable_totp(%User{} = user, code) do
    secret = user.totp_pending_secret

    if secret && NimbleTOTP.valid?(secret, code) do
      backup_codes = generate_backup_codes()
      hashed_codes = Enum.map(backup_codes, &Bcrypt.hash_pwd_salt/1)

      {:ok, user} =
        user
        |> Ecto.Changeset.change(
          totp_secret: secret,
          totp_enabled: true,
          totp_pending_secret: nil,
          totp_backup_codes: hashed_codes,
          totp_last_used_at: DateTime.utc_now()
        )
        |> Repo.update()

      {:ok, backup_codes}
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Disables TOTP for a user. Clears all TOTP fields.
  """
  def disable_totp(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      totp_secret: nil,
      totp_enabled: false,
      totp_pending_secret: nil,
      totp_backup_codes: [],
      totp_last_used_at: nil
    )
    |> Repo.update()
  end

  @doc """
  Cancels a pending TOTP setup (clears the pending secret).
  """
  def cancel_totp_setup(%User{} = user) do
    user
    |> Ecto.Changeset.change(totp_pending_secret: nil)
    |> Repo.update()
  end

  @doc """
  Verifies a TOTP code or backup code.

  Returns `:ok`, `{:error, :invalid_code}`, or `{:error, :code_already_used}`.
  """
  def verify_totp(%User{} = user, code) do
    if user.totp_enabled do
      secret = user.totp_secret

      cond do
        # Check TOTP code (with 30-second window tolerance)
        NimbleTOTP.valid?(secret, code, since: user.totp_last_used_at) ->
          user
          |> Ecto.Changeset.change(totp_last_used_at: DateTime.utc_now())
          |> Repo.update!()
          :ok

        # Check backup code
        valid_backup_code?(user, code) ->
          :ok

        true ->
          {:error, :invalid_code}
      end
    else
      :ok
    end
  end

  defp valid_backup_code?(%User{totp_backup_codes: codes}, code) when is_list(codes) do
    Enum.any?(codes, fn hashed ->
      Bcrypt.verify_pass(code, hashed)
    end)
  end

  defp valid_backup_code?(_, _), do: false

  @doc """
  Removes a used backup code after successful verification.
  """
  def consume_backup_code(%User{} = user, code) do
    remaining =
      Enum.reject(user.totp_backup_codes, fn hashed ->
        Bcrypt.verify_pass(code, hashed)
      end)

    user
    |> Ecto.Changeset.change(totp_backup_codes: remaining)
    |> Repo.update()
  end

  @doc """
  Generates 8 random backup codes (8 chars each, alphanumeric).
  """
  def generate_backup_codes do
    for _ <- 1..8 do
      :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 8)
    end
  end

  @doc """
  Checks if a user requires 2FA verification (admin/mod with TOTP enabled).
  """
  def requires_2fa?(%User{role: role, totp_enabled: true})
      when role in ["moderator", "admin", "super_admin"],
      do: true

  def requires_2fa?(_), do: false

  @doc """
  Assigns (or clears) a user's staff role.

  Requires the actor to have the `:assign_roles` permission (super_admin only).
  `role` is `"moderator"`, `"admin"`, `"super_admin"`, or `nil`/`"none"` to
  demote back to a regular user.

  Returns `{:ok, user}`, `{:error, changeset}`, or `{:error, :unauthorized}`.
  """
  def assign_role(%User{} = actor, %User{} = user, role) do
    # Rank-aware: `can?/2` alone would let an admin grant super_admin or
    # re-role a peer. See Permissions.can_assign_role?/3.
    if actor.id != user.id and Colloq.Permissions.can_assign_role?(actor, user, role) do
      role = if role in [nil, "", "none", "user"], do: nil, else: role

      user
      |> User.role_changeset(%{role: role})
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end
end
