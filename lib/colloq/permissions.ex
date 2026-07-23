defmodule Colloq.Permissions do
  @moduledoc """
  Centralized role-based permission matrix.

  Roles (ascending privilege):
    - nil           — regular user, governed by trust levels
    - "moderator"   — full moderation: warn, suspend, ban, flag resolution
    - "admin"       — content management + dashboard + user management
    - "super_admin" — everything: system config, role assignment, audit, backups
  """

  @permissions %{
    # Moderation
    view_flags:            ["moderator", "admin", "super_admin"],
    resolve_flags:         ["moderator", "admin", "super_admin"],
    hide_posts:            ["moderator", "admin", "super_admin"],
    restore_posts:         ["moderator", "admin", "super_admin"],
    edit_topics:           ["moderator", "admin", "super_admin"],
    delete_topics:         ["moderator", "admin", "super_admin"],
    warn_users:            ["moderator", "admin", "super_admin"],
    silence_users:         ["moderator", "admin", "super_admin"],
    suspend_users:         ["moderator", "admin", "super_admin"],
    ban_users:             ["moderator", "admin", "super_admin"],
    reinstate_users:       ["super_admin"],

    # Restricted ("staff only") categories: seeing them at all, and the topics
    # inside them.
    view_restricted_categories: ["moderator", "admin", "super_admin"],

    # User management
    view_users:            ["moderator", "admin", "super_admin"],
    search_users:          ["moderator", "admin", "super_admin"],
    edit_user_profile:     ["admin", "super_admin"],
    # Admins may assign roles too, but `can_assign_role?/3` limits them to
    # targets below their own rank and to roles no higher than their own — the
    # permission alone would let an admin mint a super admin.
    assign_roles:          ["admin", "super_admin"],

    # Content management
    manage_categories:     ["moderator", "admin", "super_admin"],
    manage_badges:         ["admin", "super_admin"],
    manage_automations:    ["admin", "super_admin"],
    manage_bots:           ["admin", "super_admin"],
    # Starting ResultaBot's live polling on a match thread. Moderators are
    # included because it is a match-day operational action, not a config
    # change — and someone has to be able to start it at kickoff on a Sunday.
    # Non-staff can also be designated via the `resultabot_operators` setting.
    start_match_bot:       ["moderator", "admin", "super_admin"],

    # Settings & Config
    view_settings:         ["admin", "super_admin"],
    edit_settings:         ["super_admin"],
    view_llm_settings:     ["admin", "super_admin"],
    edit_llm_settings:     ["super_admin"],
    view_x_feed_settings:  ["admin", "super_admin"],
    edit_x_feed_settings:  ["super_admin"],

    # Analytics & Dashboard
    view_dashboard:        ["admin", "super_admin"],
    view_analytics:        ["moderator", "admin", "super_admin"],

    # System
    view_audit_log:        ["super_admin"],
    manage_backups:        ["super_admin"],
    manage_billing:        ["super_admin"]
  }

  @roles ~w(super_admin admin moderator)

  @doc "Check if a user has a specific permission."
  def can?(nil, _permission), do: false
  def can?(%{role: nil}, _permission), do: false

  def can?(%{role: role}, permission) when is_atom(permission) do
    allowed_roles = Map.get(@permissions, permission, [])
    role in allowed_roles
  end

  def can?(_, _), do: false

  @doc "Check if a user has any of the given permissions."
  def can_any?(user, permissions) do
    Enum.any?(permissions, &can?(user, &1))
  end

  @doc "Returns all permissions for a given role."
  def permissions_for(role) do
    @permissions
    |> Enum.filter(fn {_perm, roles} -> role in roles end)
    |> Enum.map(fn {perm, _} -> perm end)
  end

  @doc "Returns all defined roles."
  def roles, do: @roles

  @doc "Numeric privilege rank for a role (higher = more powerful)."
  def rank("super_admin"), do: 3
  def rank("admin"), do: 2
  def rank("moderator"), do: 1
  def rank(_), do: 0

  @doc """
  Whether `actor` may take a moderation action against `target`.

  Staff can only sanction users strictly below them in rank, so a moderator
  cannot warn/silence/suspend/ban an admin (or a fellow moderator), and an
  admin cannot act on a super admin.
  """
  def can_moderate?(%{role: actor_role}, %{role: target_role}),
    do: rank(actor_role) > rank(target_role)

  def can_moderate?(_, _), do: false

  @doc """
  Whether `actor` may set `target`'s role to `new_role`.

  Two independent limits, both required:

    * the target must rank strictly below the actor — so an admin can't
      re-role a fellow admin or a super admin, and can't demote someone who
      outranks them
    * the new role must not outrank the actor — otherwise an admin could
      promote any account to super admin and then act through it

  A super admin is unaffected: it outranks every target and every grantable
  role, so it keeps assigning anything, including another super admin.
  """
  def can_assign_role?(actor, target, new_role) do
    can?(actor, :assign_roles) and
      can_moderate?(actor, target) and
      rank(normalize_role(new_role)) <= rank(Map.get(actor, :role))
  end

  # The UI submits "none" for "no role"; treat the blank variants alike.
  defp normalize_role(role) when role in [nil, "", "none", "user"], do: nil
  defp normalize_role(role), do: role

  @doc "Returns human-readable role name."
  def role_name("super_admin"), do: "Super Admin"
  def role_name("admin"), do: "Admin"
  def role_name("moderator"), do: "Moderador"
  def role_name(nil), do: "Usuario"
  def role_name(_), do: "Usuario"

  @doc """
  Staff badge config for a role, or `nil` for regular users.

  Returns `%{color, label}` used to render the Greek-helmet staff badge.
  Colors map to the app's `.badge` palette:
  gold for super admins, red for admins, green for moderators.
  """
  def staff_badge("super_admin"),
    do: %{color: "gray", label: role_name("super_admin"), icon: :helmet, count: 2}

  def staff_badge("admin"),
    do: %{color: "blue", label: role_name("admin"), icon: :helmet, count: 1}

  def staff_badge("moderator"),
    do: %{color: "green", label: role_name("moderator"), icon: :hardhat, count: 1}

  def staff_badge(_), do: nil

  @staff_roles ~w(moderator admin super_admin)

  @doc """
  Whether a user (or role string) is staff — moderator, admin, or super admin.
  Regular users and `nil` are not staff. Used to gate staff-only visibility such
  as trust levels.
  """
  def staff?(%{role: role}), do: staff?(role)
  def staff?(role) when is_binary(role), do: role in @staff_roles
  def staff?(_), do: false

  @doc "Returns a human-readable permission name in Spanish."
  def permission_name(:view_flags), do: "Ver reportes"
  def permission_name(:resolve_flags), do: "Resolver reportes"
  def permission_name(:hide_posts), do: "Ocultar posts"
  def permission_name(:warn_users), do: "Advertir usuarios"
  def permission_name(:suspend_users), do: "Suspender usuarios"
  def permission_name(:ban_users), do: "Banear usuarios"
  def permission_name(:reinstate_users), do: "Reintegrar usuarios"
  def permission_name(:view_users), do: "Ver usuarios"
  def permission_name(:search_users), do: "Buscar usuarios"
  def permission_name(:assign_roles), do: "Asignar roles"
  def permission_name(:view_restricted_categories), do: "Ver categorías restringidas"
  def permission_name(:manage_categories), do: "Gestionar categorías"
  def permission_name(:manage_badges), do: "Gestionar insignias"
  def permission_name(:manage_automations), do: "Gestionar automatizaciones"
  def permission_name(:manage_bots), do: "Gestionar bots"
  def permission_name(:view_settings), do: "Ver configuración"
  def permission_name(:edit_settings), do: "Editar configuración"
  def permission_name(:view_dashboard), do: "Ver panel de control"
  def permission_name(:view_audit_log), do: "Ver auditoría"
  def permission_name(:manage_backups), do: "Gestionar backups"
  def permission_name(:manage_billing), do: "Gestionar facturación"
  def permission_name(_), do: "Desconocido"
end
