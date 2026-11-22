defmodule Colloq.DataSource do
  @moduledoc """
  Which football data provider answers each area of the site: Sofascore or
  FotMob.

  Both are unofficial APIs that can start refusing the server at any time, so
  each area is switchable from the admin panel instead of hard-wired. The
  selected provider is asked first; the other one stays the automatic fallback
  wherever the area supports it, so flipping the switch only changes the order.

  Areas:

    * `:prode` — the Prode's fechas (fixtures, current round, results, scoring)
    * `:standings` — the league table (commands and the full-time post)
    * `:matchday` — live match threads (score banner, team sheet, goals, cards)

  Player features (cards, comparisons, squads) are Sofascore-only and not
  covered here.

  Stored as `data_source_<area>` site settings. Read on hot paths (every Prode
  page, every live poll), so the values are cached in `:persistent_term`.
  `Colloq.SiteSettings` drops that cache on every write, so a change made from
  either admin page applies on the next read.
  """

  alias Colloq.SiteSettings

  @providers ~w(sofascore fotmob)
  @defaults %{prode: "fotmob", standings: "sofascore", matchday: "sofascore"}
  @cache {__MODULE__, :sources}

  @doc "The switchable areas, in display order."
  def areas, do: [:prode, :standings, :matchday]

  @doc "Provider names a setting may hold."
  def providers, do: @providers

  @doc "Setting key for an area."
  def key(area) when is_map_key(@defaults, area), do: "data_source_#{area}"

  @doc "The provider for `area`, as `:sofascore` or `:fotmob`."
  def get(area) when is_map_key(@defaults, area) do
    all() |> Map.fetch!(area) |> String.to_existing_atom()
  end

  @doc "The provider for `area` and the fallback, in the order to try them."
  def order(area) do
    case get(area) do
      :fotmob -> [:fotmob, :sofascore]
      :sofascore -> [:sofascore, :fotmob]
    end
  end

  @doc "Every area's provider as strings, e.g. `%{prode: \"fotmob\", ...}`."
  def all do
    case :persistent_term.get(@cache, nil) do
      nil ->
        values =
          Map.new(@defaults, fn {area, default} ->
            value = SiteSettings.get(key(area))
            {area, if(value in @providers, do: value, else: default)}
          end)

        :persistent_term.put(@cache, values)
        values

      cached ->
        cached
    end
  end

  @doc "Sets the provider for `area`."
  def put(area, provider) when is_map_key(@defaults, area) do
    provider = to_string(provider)

    if provider in @providers do
      SiteSettings.put(key(area), provider,
        group: "match_day",
        description: "Proveedor de datos para #{area} (sofascore | fotmob)"
      )
    else
      {:error, {:invalid_provider, provider}}
    end
  end

  @doc "Drops the cached values."
  def clear_cache, do: :persistent_term.erase(@cache)
end
