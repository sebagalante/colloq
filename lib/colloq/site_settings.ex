defmodule Colloq.SiteSettings do
  @moduledoc """
  Site settings context — key-value store for configuration.
  Supports string, integer, boolean, json, and secret types.
  Secrets are masked in UI and never returned in API responses.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.SiteSettings.Setting

  def get(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> nil
      setting -> cast_value(setting)
    end
  end

  def get!(key) do
    setting = Repo.get_by!(Setting, key: key)
    cast_value(setting)
  end

  def put(key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "string")
    group = Keyword.get(opts, :group, "general")
    description = Keyword.get(opts, :description)

    case Repo.get_by(Setting, key: key) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{
          key: key,
          value: to_string(value),
          type: type,
          group: group,
          description: description
        })
        |> Repo.insert()

      setting ->
        setting
        |> Setting.changeset(%{value: to_string(value), type: type})
        |> Repo.update()
    end
  end

  def list_by_group(group) do
    Setting
    |> where([s], s.group == ^group)
    |> Repo.all()
  end

  def list_keys do
    Setting
    |> select([s], s.key)
    |> Repo.all()
  end

  defp cast_value(%Setting{type: "integer"} = s) do
    case Integer.parse(s.value) do
      {int, _} -> int
      :error -> s.value
    end
  end

  defp cast_value(%Setting{type: "boolean"} = s) do
    String.downcase(s.value) in ["true", "1", "yes"]
  end

  defp cast_value(%Setting{type: "json"} = s) do
    Jason.decode!(s.value)
  rescue
    _ -> s.value
  end

  defp cast_value(%Setting{type: "secret"} = _s) do
    nil
  end

  defp cast_value(%Setting{} = s), do: s.value
end