defmodule Colloq.SiteSettings do
  @moduledoc """
  Site settings context — key-value store for configuration.
  Supports string, integer, boolean, json, and secret types.
  Secrets are masked in UI and never returned in API responses.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.SiteSettings.Setting

  # Settings whose value is one of a fixed set. Stored as plain strings (the
  # `type` column describes the cast, not the domain), so the allowed values
  # live here — the admin UI renders a dropdown from this list instead of a
  # free-text box where a typo silently misconfigures the site.
  @allowed_values %{
    "registration_mode" => ~w(open invite closed),
    "spam_ml_mode" => ~w(shadow enforce)
  }

  @doc """
  Allowed values for `key`, or `nil` when the setting is free-form.
  """
  def allowed_values(key), do: Map.get(@allowed_values, key)

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

    with allowed when is_list(allowed) <- allowed_values(key),
         false <- to_string(value) in allowed do
      {:error, {:invalid_value, key, allowed}}
    else
      _ -> do_put(key, value, type, group, description)
    end
  end

  # Branding is read on *every* page render (header, <title>, favicon), so it is
  # cached rather than hitting the DB four times per request. Any write clears
  # the cache, so a change in the admin panel shows up on the next page load.
  @branding_cache {__MODULE__, :branding}
  @branding_keys ~w(site_title site_description site_logo site_favicon)

  @doc """
  Site branding as a map of `%{title, description, logo, favicon}`.

  Falls back to the built-in name when `site_title` is unset, so the header is
  never blank. Cached in `:persistent_term`; see `clear_branding_cache/0`.
  """
  def branding do
    case :persistent_term.get(@branding_cache, nil) do
      nil ->
        values =
          Setting
          |> where([s], s.key in ^@branding_keys)
          |> Repo.all()
          |> Map.new(&{&1.key, blank_to_nil(&1.value)})

        branding = %{
          title: values["site_title"] || "Colloq",
          description: values["site_description"],
          logo: values["site_logo"],
          favicon: values["site_favicon"]
        }

        :persistent_term.put(@branding_cache, branding)
        branding

      cached ->
        cached
    end
  end

  @doc "Drops the branding cache. Called on every write."
  def clear_branding_cache, do: :persistent_term.erase(@branding_cache)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp do_put(key, value, type, group, description) do
    clear_branding_cache()

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

  @doc """
  Removes a setting entirely.

  Needed because `Setting.changeset/2` requires a non-blank value for every type
  but `image`, so a list-shaped setting can't be emptied by writing `""` — the
  update just fails. Deleting the row is how "no value" is expressed; readers
  already treat a missing key and an empty one the same.
  """
  def delete(key) do
    clear_branding_cache()

    case Repo.get_by(Setting, key: key) do
      nil -> {:ok, :not_found}
      setting -> Repo.delete(setting)
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