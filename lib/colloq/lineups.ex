defmodule Colloq.Lineups do
  @moduledoc """
  Formation layouts and squad → starting XI assignment for the lineup board.

  Coordinates are percentages of the pitch — `x` 0 (left) → 100 (right) and
  `y` 0 (attacking third) → 100 (own goal) — so a board is responsive and
  renders identically wherever it's drawn.

  Formations are **parsed, not hardcoded**: any `"N-N-…"` string whose outfield
  players total 10 lays out automatically (4-4-2, 4-2-3-1, 3-5-2, …). Rows run
  defence → attack; the first row is the back line, the last is the attack, and
  anything between is midfield.

  Players come from the `sofascore_players` table via `Colloq.Sofascore`.
  """

  alias Colloq.Sofascore

  @formations ~w(4-4-2 4-3-3 4-3-1-2 4-2-3-1 4-1-4-1 4-4-1-1 4-5-1 3-5-2 3-4-3 5-3-2)

  # `position` values as stored in the DB (Sofascore G/D/M/F, already
  # translated to Spanish by Colloq.Sofascore).
  @gk "Arquero"
  @def "Defensor"
  @mid "Mediocampista"
  @fwd "Delantero"

  @doc "Formations offered in the picker (any valid string also works)."
  def formations, do: @formations

  @doc """
  Parses a formation into outfield row counts, defence → attack.

      iex> Colloq.Lineups.parse_formation("4-3-1-2")
      {:ok, [4, 3, 1, 2]}

  Returns `:error` unless the outfield players total 10 across 2–5 rows.
  """
  def parse_formation(formation) when is_binary(formation) do
    parsed =
      formation
      |> String.trim()
      |> String.split("-", trim: true)
      |> Enum.map(&Integer.parse/1)

    if Enum.any?(parsed, &(&1 == :error)) do
      :error
    else
      rows = Enum.map(parsed, fn {n, _rest} -> n end)

      if length(rows) in 2..5 and Enum.sum(rows) == 10 and Enum.all?(rows, &(&1 > 0)) do
        {:ok, rows}
      else
        :error
      end
    end
  end

  def parse_formation(_), do: :error

  @doc "Whether a formation string is layable out."
  def valid_formation?(formation), do: match?({:ok, _}, parse_formation(formation))

  @doc """
  Pitch slots for a formation: the keeper plus one entry per outfield player,
  each `%{role: :gk | :def | :mid | :fwd, x: float, y: float}`.
  Returns `[]` for an invalid formation.
  """
  def layout(formation) do
    case parse_formation(formation) do
      {:ok, rows} -> [%{role: :gk, x: 50.0, y: 88.0} | outfield_slots(rows)]
      :error -> []
    end
  end

  @doc """
  Builds a starting XI for `team` (atom key or Sofascore `team_id`) in
  `formation`, using the squad stored in the DB.

  Players are auto-assigned by their stored position; if a bucket runs short the
  slot is filled from whoever is left (and stays `nil` if the squad is too
  small). Everyone not in the XI comes back as `:bench`.

  Returns `%{slots: [%{role, x, y, player}], bench: [player]}`.
  """
  def build(team, formation) do
    squad = Sofascore.list_by_team(team)

    case layout(formation) do
      [] ->
        %{slots: [], bench: Enum.sort_by(squad, & &1.name)}

      slots ->
        {filled, leftover} =
          Enum.map_reduce(slots, bucket(squad), fn slot, buckets ->
            {player, buckets} = take(buckets, slot.role)
            {Map.put(slot, :player, player), buckets}
          end)

        %{slots: filled, bench: flatten(leftover)}
    end
  end

  # --- layout -------------------------------------------------------------

  defp outfield_slots(rows) do
    ys = row_ys(length(rows))
    last = length(rows) - 1

    rows
    |> Enum.zip(ys)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{count, y}, idx} ->
      role =
        cond do
          idx == 0 -> :def
          idx == last -> :fwd
          true -> :mid
        end

      Enum.map(spread(count), &%{role: role, x: &1, y: y})
    end)
  end

  # Rows run from the back line (y 72) up to the attack (y 18).
  defp row_ys(1), do: [45.0]

  defp row_ys(n) do
    step = 54.0 / (n - 1)
    Enum.map(0..(n - 1), fn i -> Float.round(72.0 - i * step, 1) end)
  end

  # Evenly spread `n` players across the width; thinner rows sit further in.
  defp spread(1), do: [50.0]

  defp spread(n) do
    margin = Map.get(%{2 => 34.0, 3 => 22.0, 4 => 12.0, 5 => 10.0}, n, 8.0)
    step = (100.0 - 2 * margin) / (n - 1)
    Enum.map(0..(n - 1), fn i -> Float.round(margin + i * step, 1) end)
  end

  # --- squad assignment ---------------------------------------------------

  defp bucket(squad) do
    %{
      gk: Enum.filter(squad, &(&1.position == @gk)),
      def: Enum.filter(squad, &(&1.position == @def)),
      mid: Enum.filter(squad, &(&1.position == @mid)),
      fwd: Enum.filter(squad, &(&1.position == @fwd)),
      other: Enum.filter(squad, &(&1.position not in [@gk, @def, @mid, @fwd]))
    }
  end

  defp take(buckets, role) do
    case Map.fetch!(buckets, role) do
      [player | rest] -> {player, Map.put(buckets, role, rest)}
      [] -> take_any(buckets, role)
    end
  end

  # A thin squad still fields 11: borrow from the nearest non-empty bucket.
  defp take_any(buckets, role) do
    order = [:other, :mid, :def, :fwd, :gk] -- [role]

    case Enum.find(order, fn key -> Map.fetch!(buckets, key) != [] end) do
      nil ->
        {nil, buckets}

      key ->
        [player | rest] = Map.fetch!(buckets, key)
        {player, Map.put(buckets, key, rest)}
    end
  end

  defp flatten(buckets) do
    buckets |> Map.values() |> List.flatten() |> Enum.sort_by(& &1.name)
  end
end
