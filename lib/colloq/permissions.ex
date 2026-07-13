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
    warn_users:            ["moderator", "admin", "super_admin"],
    silence_users:         ["moderator", "admin", "super_admin"],
    suspend_users:         ["moderator", "admin", "super_admin"],
    ban_users:             ["moderator", "admin", "super_admin"],
    reinstate_users:       ["super_admin"],

    # User management
    view_users:            ["moderator", "admin", "super_admin"],
    search_users:          ["moderator", "admin", "super_admin"],
    edit_user_profile:     ["admin", "super_admin"],
    assign_roles:          ["super_admin"],

    # Content management
    manage_categories:     ["moderator", "admin", "super_admin"],
    manage_badges:         ["admin", "super_admin"],
    manage_automations:    ["admin", "super_admin"],
    manage_bots:           ["admin", "super_admin"],

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

  @doc "Returns human-readable role name."
  def role_name("super_admin"), do: "Super Admin"
  def role_name("admin"), do: "Admin"
  def role_name("moderator"), do: "Moderador"
  def role_name(nil), do: "Usuario"
  def role_name(_), do: "Usuario"

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
