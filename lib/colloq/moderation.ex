defmodule Colloq.Moderation do
  @moduledoc """
  Forum moderation context.

  Supports flagging posts, resolving flags, hiding posts, and
  automatic moderation via blocked words or spam detection.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Moderation.Flag
  alias Colloq.Forum.Post

  @doc """
  Creates a flag (report) on a post.

  Returns `{:ok, flag}` or `{:error, changeset}`.
  """
  def flag_post(post_id, user_id, reason) do
    %Flag{}
    |> Flag.changeset(%{
      post_id: post_id,
      user_id: user_id,
      reason: reason
    })
    |> Repo.insert()
  end

  @doc """
  Resolves an existing flag.

  Marks the flag as resolved, recording who resolved it and the resolution text.

  Returns `{:ok, flag}` or `{:error, changeset}`.
  """
  def resolve_flag(flag_id, resolver_id, resolution) do
    flag = Repo.get!(Flag, flag_id)

    flag
    |> Flag.changeset(%{
      resolved: true,
      resolved_at: DateTime.utc_now(),
      resolved_by_id: resolver_id,
      resolution: resolution
    })
    |> Repo.update()
  end

  @doc """
  Lists pending (unresolved) flags, most recent first.

  Returns `[%Flag{}]` with `:post` and `:user` preloaded.
  """
  def list_pending_flags do
    Flag
    |> where([f], f.resolved == false)
    |> preload([:post, :user])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Hides a post by soft-deleting it and flagging it as a moderation removal.

  `actor` is the moderator who hid it, or `nil` for a system action (spam /
  profanity auto-moderation). Setting `hidden: true` is what puts the post in
  the moderation queue — user self-deletions (`Forum.delete_post/2`) stay out.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def hide_post(%Post{} = post, actor \\ nil) do
    post
    |> Ecto.Changeset.change(
      deleted_at: DateTime.utc_now(),
      hidden: true,
      deleted_by_id: actor && actor.id
    )
    |> Repo.update()
    # Hiding sets deleted_at directly rather than going through
    # Forum.delete_post/2, so it has to resync the counters itself — otherwise
    # a hidden post keeps being counted in the topic and on the author.
    |> tap_resync()
  end

  @doc """
  Restores a previously hidden post: clears `deleted_at`, `hidden`, and
  `deleted_by_id`.

  Returns `{:ok, post}` or `{:error, changeset}`.
  """
  def restore_post(%Post{} = post) do
    post
    |> Ecto.Changeset.change(deleted_at: nil, hidden: false, deleted_by_id: nil)
    |> Repo.update()
    |> tap_resync()
  end

  # Recompute the topic and author post counts from what's actually visible.
  # Passing the result through unchanged keeps hide/restore's return contract.
  defp tap_resync({:ok, %Post{} = post} = result) do
    Colloq.Forum.resync_post_counts(post)
    result
  end

  defp tap_resync(other), do: other

  @doc """
  Lists posts hidden by moderation/system (not user self-deletions), most
  recently hidden first.

  Returns `[%Post{}]` with `:user`, `:topic`, and `:deleted_by` preloaded.
  """
  def list_hidden_posts(limit \\ 50) do
    Post
    |> where([p], p.hidden == true and not is_nil(p.deleted_at))
    |> order_by(desc: :deleted_at)
    |> limit(^limit)
    |> preload([:user, :topic, :deleted_by])
    |> Repo.all()
  end

  @doc """
  Runs automatic moderation on a new post.

  Checks the post body against a list of blocked words from site settings.
  If any match, the post is hidden automatically. Optionally runs spam
  detection if enabled.

  Returns `:ok`, `{:blocked, :profanity}`, or `{:blocked, :spam}`.
  """
  def auto_moderate(%Post{} = post) do
    blocked_words = load_blocked_words()

    cond do
      contains_blocked_word?(post.body, blocked_words) ->
        hide_post(post)
        {:blocked, :profanity}

      should_check_spam?() ->
        spam_score = spam_detector(post)
        if spam_score > 0.8, do: hide_post(post)
        if spam_score > 0.8, do: {:blocked, :spam}, else: :ok

      true ->
        :ok
    end
  end

  defp load_blocked_words do
    case Colloq.SiteSettings.get("blocked_words") do
      nil -> []
      words when is_binary(words) -> String.split(words, ",", trim: true) |> Enum.map(&String.trim/1)
      words when is_list(words) -> words
    end
  end

  defp contains_blocked_word?(nil, _), do: false
  defp contains_blocked_word?(body, words) do
    body_downcase = String.downcase(body)
    Enum.any?(words, fn w -> String.contains?(body_downcase, String.downcase(w)) end)
  end

  defp should_check_spam? do
    Colloq.SiteSettings.get("spam_detection_enabled") == true
  end

  @doc """
  Heuristic spam detector (no external service).

  Returns a score between 0.0 and 1.0, where 1.0 is certainly spam.
  """
  def spam_detector(%Post{} = post) do
    scores = [
      url_spam_score(post),
      duplicate_score(post),
      keyword_score(post)
    ]
    Enum.max(scores)
  end

  defp url_spam_score(%Post{body: body}) do
    url_count = Regex.scan(~r/https?:\/\//, body) |> length()
    cond do
      url_count > 5 -> 0.95
      url_count > 3 -> 0.6
      true -> 0.0
    end
  end

  defp duplicate_score(%Post{id: post_id, body: body, user_id: user_id}) do
    import Ecto.Query

    similar = from(p in Post,
      where: p.user_id == ^user_id,
      where: p.body == ^body,
      where: p.id != ^post_id,
      order_by: [desc: p.inserted_at],
      limit: 1
    ) |> Repo.one()

    if similar, do: 0.9, else: 0.0
  end

  defp keyword_score(%Post{body: body}) do
    blocked = Colloq.SiteSettings.get("blocked_keywords")
    if is_list(blocked) and length(blocked) > 0 do
      matches = Enum.count(blocked, fn kw -> String.contains?(String.downcase(body), String.downcase(kw)) end)
      min(matches * 0.25, 1.0)
    else
      0.0
    end
  end

  # =========================================================================
  # User Moderation — warn, suspend, ban, reinstate
  # =========================================================================

  alias Colloq.Accounts.User
  alias Colloq.Permissions

  @doc """
  Issues a warning to a user, with an optional `reason` explaining why.

  Requires actor to have :warn_users permission.
  Increments `warnings_count`, records `last_warning_at`/`last_warning_reason`,
  and notifies the warned user (with the reason so they know what to fix).
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def warn_user(%User{} = actor, %User{} = user, reason \\ nil) do
    cond do
      not Permissions.can?(actor, :warn_users) -> {:error, :unauthorized}
      not Permissions.can_moderate?(actor, user) -> {:error, :forbidden}
      true -> do_warn_user(actor, user, reason)
    end
  end

  defp do_warn_user(actor, user, reason) do
    reason = normalize_reason(reason)

    result =
      user
      |> Ecto.Changeset.change(
        warnings_count: user.warnings_count + 1,
        last_warning_at: DateTime.utc_now(),
        last_warning_reason: reason
      )
      |> Repo.update()

    with {:ok, updated} <- result do
      notify_warning(updated, actor, reason)
      {:ok, updated}
    end
  end

  defp normalize_reason(nil), do: nil

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A warning must always reach the user, so the actor is stored under
  # "moderator_id" (not "actor_id") to bypass the blocked-actor skip in
  # create_notification.
  defp notify_warning(%User{} = user, %User{} = actor, reason) do
    Colloq.Notifications.create_notification(%{
      user_id: user.id,
      type: "warning",
      title: "Recibiste una advertencia de moderación",
      body: reason || "Revisá las normas de la comunidad.",
      data: %{"moderator_id" => actor.id, "moderator_username" => actor.username}
    })
  end

  @doc """
  Suspends a user for a given duration.

  Requires actor to have :suspend_users permission.
  `duration` is a string like "2_hours", "1_day", "7_days", "30_days".

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def suspend_user(%User{} = actor, %User{} = user, duration, reason \\ nil) do
    cond do
      not Permissions.can?(actor, :suspend_users) ->
        {:error, :unauthorized}

      not Permissions.can_moderate?(actor, user) ->
        {:error, :forbidden}

      true ->
        user
        |> Ecto.Changeset.change(
          suspended_until: parse_duration(duration),
          suspended_at: DateTime.utc_now(),
          suspension_reason: reason
        )
        |> Repo.update()
    end
  end

  @doc """
  Silences a user for a given duration.

  A silenced user can still log in and read, but cannot create topics or
  reply. Requires actor to have :silence_users permission.
  `duration` is a string like "2_hours", "1_day", "7_days".

  Returns `{:ok, user}` or `{:error, changeset | :unauthorized}`.
  """
  def silence_user(%User{} = actor, %User{} = user, duration, reason \\ nil) do
    cond do
      not Permissions.can?(actor, :silence_users) ->
        {:error, :unauthorized}

      not Permissions.can_moderate?(actor, user) ->
        {:error, :forbidden}

      true ->
        user
        |> Ecto.Changeset.change(
          silenced_until: parse_duration(duration),
          silenced_at: DateTime.utc_now(),
          silence_reason: reason
        )
        |> Repo.update()
    end
  end

  @doc """
  Lifts a silence, letting the user post again.

  Requires actor to have :silence_users permission.
  """
  def unsilence_user(%User{} = actor, %User{} = user) do
    if Permissions.can?(actor, :silence_users) do
      user
      |> Ecto.Changeset.change(silenced_until: nil, silenced_at: nil, silence_reason: nil)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Bans a user permanently.

  Requires actor to have :ban_users permission.
  Sets `banned: true`, `banned_at`, and `ban_reason`.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def ban_user(%User{} = actor, %User{} = user, reason \\ nil) do
    cond do
      not Permissions.can?(actor, :ban_users) ->
        {:error, :unauthorized}

      not Permissions.can_moderate?(actor, user) ->
        {:error, :forbidden}

      true ->
        user
        |> Ecto.Changeset.change(
          banned: true,
          banned_at: DateTime.utc_now(),
          ban_reason: reason
        )
        |> Repo.update()
    end
  end

  @doc """
  Lifts a suspension or ban (reinstates the user).

  Requires actor to have :reinstate_users permission (super_admin only).
  Clears all moderation fields.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def reinstate_user(%User{} = actor, %User{} = user) do
    if Permissions.can?(actor, :reinstate_users) do
      user
      |> Ecto.Changeset.change(
        suspended_until: nil,
        suspended_at: nil,
        suspension_reason: nil,
        silenced_until: nil,
        silenced_at: nil,
        silence_reason: nil,
        banned: false,
        banned_at: nil,
        ban_reason: nil
      )
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Checks if a user is currently blocked (banned or suspended).
  Returns `:active`, `:suspended`, or `:banned`.
  """
  def check_user_status(%User{} = user) do
    User.moderation_status(user)
  end

  @doc """
  Lists all suspended or banned users.
  """
  def list_blocked_users do
    now = DateTime.utc_now()

    from(u in User,
      where: u.banned == true or u.suspended_until > ^now,
      order_by: [desc: u.banned_at, desc: u.suspended_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists all currently-sanctioned users (banned, suspended, or silenced),
  most recently actioned first.
  """
  def list_sanctioned_users do
    now = DateTime.utc_now()

    from(u in User,
      where: u.banned == true or u.suspended_until > ^now or u.silenced_until > ^now,
      order_by: [desc: u.banned_at, desc: u.suspended_at, desc: u.silenced_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists users with warnings.
  """
  def list_warned_users do
    from(u in User,
      where: u.warnings_count > 0,
      order_by: [desc: u.last_warning_at]
    )
    |> Repo.all()
  end

  defp parse_duration("2_hours"), do: DateTime.add(DateTime.utc_now(), 2, :hour)
  defp parse_duration("6_hours"), do: DateTime.add(DateTime.utc_now(), 6, :hour)
  defp parse_duration("1_day"), do: DateTime.add(DateTime.utc_now(), 1, :day)
  defp parse_duration("3_days"), do: DateTime.add(DateTime.utc_now(), 3, :day)
  defp parse_duration("7_days"), do: DateTime.add(DateTime.utc_now(), 7, :day)
  defp parse_duration("30_days"), do: DateTime.add(DateTime.utc_now(), 30, :day)
  defp parse_duration("90_days"), do: DateTime.add(DateTime.utc_now(), 90, :day)
  defp parse_duration(_), do: DateTime.add(DateTime.utc_now(), 1, :day)
end
