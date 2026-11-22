defmodule Colloq.Predictions.FixtureMatch do
  @moduledoc """
  Pairs stored predictions with the matches of a fecha, whichever provider
  listed them.

  A prediction keeps the id of the match it was made on, but Sofascore and
  FotMob ids have nothing in common, so after the Prode's data source is
  switched the id no longer matches. The fallback is the teams: within one
  fecha every club plays once, so the match whose home and away names are most
  alike is the same game.

  Names differ between providers ("Estudiantes" vs "Estudiantes de La Plata",
  accents, "CA" prefixes), so this scores similarity rather than testing
  equality, and assigns each match to at most one prediction. Predictions made
  before team names were stored only pair by id.
  """

  # Words that say nothing about which club it is.
  @filler ~w(de del la el los las club atletico ca cd fc ac sc sociedad asociacion deportiva deportivo)

  @doc """
  Pairs `predictions` (all for the same fecha) with `matches`, given as maps
  with `:fixture_id`, `:home` and `:away`. Returns `%{fixture_id => prediction}`
  keyed by the *match's* id, so callers look predictions up by what they show.
  """
  def pair(predictions, matches) do
    by_id = Map.new(predictions, &{&1.fixture_id, &1})

    {exact, rest} =
      Enum.split_with(matches, &Map.has_key?(by_id, to_string(&1.fixture_id)))

    paired = Map.new(exact, &{to_string(&1.fixture_id), by_id[to_string(&1.fixture_id)]})
    used = MapSet.new(Map.values(paired), & &1.id)

    candidates =
      Enum.reject(predictions, &(MapSet.member?(used, &1.id) or is_nil(&1.home_team) or is_nil(&1.away_team)))

    # Best-scoring pairs first, each match and prediction used once.
    for(m <- rest, p <- candidates, score = similarity(p, m), score > 0, do: {score, m, p})
    |> Enum.sort_by(fn {score, _m, _p} -> score end, :desc)
    |> Enum.reduce({paired, MapSet.new(), MapSet.new()}, fn {_score, m, p}, {acc, seen_m, seen_p} ->
      id = to_string(m.fixture_id)

      if MapSet.member?(seen_m, id) or MapSet.member?(seen_p, p.id),
        do: {acc, seen_m, seen_p},
        else: {Map.put(acc, id, p), MapSet.put(seen_m, id), MapSet.put(seen_p, p.id)}
    end)
    |> elem(0)
  end

  # Both sides have to look alike; a shared home team alone is not the match.
  defp similarity(prediction, match) do
    home = team_similarity(prediction.home_team, match.home)
    away = team_similarity(prediction.away_team, match.away)

    if home > 0 and away > 0, do: home + away, else: 0
  end

  @doc false
  def team_similarity(a, b) do
    {na, nb} = {normalize(a), normalize(b)}

    cond do
      na == "" or nb == "" ->
        0.0

      na == nb ->
        1.0

      true ->
        ta = tokens(na)
        tb = tokens(nb)
        union = MapSet.union(ta, tb) |> MapSet.size()

        if union == 0,
          do: 0.0,
          else: MapSet.size(MapSet.intersection(ta, tb)) / union
    end
  end

  defp tokens(name) do
    name
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @filler or String.length(&1) < 3))
    |> MapSet.new()
  end

  defp normalize(nil), do: ""

  defp normalize(name) do
    name
    |> to_string()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.trim()
  end
end
