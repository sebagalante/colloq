defmodule Colloq.Sofascore.TeamSheet do
  @moduledoc """
  Flattens the `/event/{id}` and `/event/{id}/lineups` payloads into the shape
  the matchday card renders — both XIs, benches, absentees and the referee.

  The result is stored verbatim in a system post's `event_data`, so everything
  here has to survive a JSON round-trip: string keys only, no atoms, no structs.
  Reading it back from the database must give exactly what building it did.

  Lineups may be `nil`. Sofascore publishes them about an hour before kickoff
  and some matches never get them at all, so the card degrades to the referee
  alone rather than not being posted.
  """

  alias Colloq.Sofascore

  @doc """
  Build the card data. `lineups` is the `/lineups` payload or `nil`.
  """
  def build(event, lineups \\ nil) when is_map(event) do
    %{
      "confirmed" => lineups != nil and lineups["confirmed"] == true,
      "has_lineups" => lineups != nil,
      "home" => team(event["homeTeam"], lineups && lineups["home"]),
      "away" => team(event["awayTeam"], lineups && lineups["away"]),
      "referee" => referee(event)
    }
  end

  defp team(team, side) do
    players = side |> Kernel.||(%{}) |> Map.get("players") |> List.wrap()

    %{
      "name" => (team && team["name"]) || "?",
      "crest" => team && team["id"] && crest(team["id"]),
      "formation" => side && side["formation"],
      "starters" => players |> Enum.reject(& &1["substitute"]) |> Enum.map(&player/1),
      "bench" => players |> Enum.filter(& &1["substitute"]) |> Enum.map(&player/1),
      "missing" => side |> Kernel.||(%{}) |> Map.get("missingPlayers") |> List.wrap() |> Enum.map(&absent/1),
      "kit" => kit(side && side["playerColor"]),
      "gk_kit" => kit(side && side["goalkeeperColor"])
    }
  end

  defp player(entry) do
    person = entry["player"] || %{}

    %{
      "number" => entry["shirtNumber"] || entry["jerseyNumber"],
      "name" => person["shortName"] || person["name"] || "?",
      "gk" => entry["position"] == "G"
    }
  end

  defp absent(entry) do
    person = entry["player"] || %{}

    %{
      "name" => person["shortName"] || person["name"] || "?",
      "reason" => reason_label(entry["description"])
    }
  end

  defp referee(event) do
    case Sofascore.referee(event) do
      nil ->
        nil

      ref ->
        %{
          "name" => ref.name,
          "country" => ref.country,
          "games" => ref.games,
          "yellow" => ref.yellow,
          "red" => ref.red,
          "yellow_red" => ref.yellow_red
        }
    end
  end

  # Kit colors arrive as bare hex digits and end up in an inline `style`, so
  # anything that isn't six hex digits is dropped for a neutral kit.
  @default_kit %{"primary" => "1b2431", "number" => "e6e9ef", "outline" => "3a4658"}

  defp kit(%{} = colors) do
    %{
      "primary" => hex(colors["primary"], @default_kit["primary"]),
      "number" => hex(colors["number"], @default_kit["number"]),
      "outline" => hex(colors["outline"], @default_kit["outline"])
    }
  end

  defp kit(_), do: @default_kit

  defp hex(value, fallback) when is_binary(value) do
    if String.match?(value, ~r/\A[0-9a-fA-F]{6}\z/), do: value, else: fallback
  end

  defp hex(_value, fallback), do: fallback

  # Sofascore mixes machine codes ("red_card_suspension") with free English text
  # ("Foot Injury") in the same field.
  defp reason_label(nil), do: nil

  defp reason_label(description) do
    down = String.downcase(description)

    cond do
      String.contains?(down, "injury") -> "Lesión"
      String.contains?(down, "red_card") -> "Suspendido"
      String.contains?(down, "yellow") -> "Suspendido"
      String.contains?(down, "suspend") -> "Suspendido"
      String.contains?(down, "national") -> "Selección"
      String.contains?(down, "doubt") -> "En duda"
      true -> String.replace(description, "_", " ")
    end
  end

  defp crest(id), do: "https://api.sofascore.com/api/v1/team/#{id}/image"
end
