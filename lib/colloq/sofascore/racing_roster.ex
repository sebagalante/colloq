defmodule Colloq.Sofascore.RacingRoster do
  @moduledoc """
  Racing Club's first-team squad, from the official site
  (racingclub.com.ar/futbol/primer-equipo/plantel), captured 2026-07-24.

  This is the authority for Racing — Sofascore's feed lags on transfers and
  loan numbers (it had Lautaro Díaz on #19 clashing with Rodríguez, was missing
  De Bellis, and carried departed players). `Colloq.Sofascore.apply_racing_roster/0`
  reconciles the `sofascore_players` rows to this list.

  Update it by re-capturing the page and editing the list below; there's an
  admin button that re-applies it.
  """

  @players [
    %{number: 1, name: "Francisco Gómez", surname: "Gómez", position: "Arquero"},
    %{number: 2, name: "Agustín Eugenio García Basso", surname: "García Basso", position: "Defensor"},
    %{number: 3, name: "Marco Genaro Di Cesare", surname: "Di Cesare", position: "Defensor"},
    %{number: 4, name: "Ezequiel Cannavo", surname: "Cannavo", position: "Defensor"},
    %{number: 5, name: "Claudio Matías Kranevitter", surname: "Kranevitter", position: "Mediocampista"},
    %{number: 6, name: "Marcos Alberto Rojo", surname: "Rojo", position: "Defensor"},
    %{number: 7, name: "Duván Andrés Vergara", surname: "Vergara", position: "Delantero"},
    %{number: 8, name: "Alan Forneris", surname: "Forneris", position: "Mediocampista"},
    %{number: 9, name: "Adrián Emmanuel Martínez", surname: "Martínez", position: "Delantero"},
    %{number: 10, name: "Matko Mijael Miljevic", surname: "Miljevic", position: "Mediocampista"},
    %{number: 11, name: "Federico Matías Zaracho", surname: "Zaracho", position: "Mediocampista"},
    %{number: 12, name: "Thiago De Bellis", surname: "De Bellis", position: "Arquero"},
    # Two Sosas in the squad, so #13 is disambiguated on the pitch.
    %{number: 13, name: "Santiago Sosa", surname: "Sosa", short: "S. Sosa", position: "Mediocampista"},
    %{number: 15, name: "Gastón Nicolás Martirena", surname: "Martirena", position: "Defensor"},
    %{number: 16, name: "Diego Ulises Ortegoza", surname: "Ortegoza", position: "Mediocampista"},
    %{number: 17, name: "Tomás José Conechny", surname: "Conechny", position: "Delantero"},
    %{number: 18, name: "Luis Alfonso Espino", surname: "Espino", position: "Defensor"},
    %{number: 19, name: "Ignacio Agustín Rodríguez", surname: "Rodríguez", position: "Defensor"},
    %{number: 20, name: "Baltasar Luis Rodríguez", surname: "Luis Rodríguez", position: "Mediocampista"},
    %{number: 21, name: "Valentín Carboni", surname: "Carboni", position: "Delantero"},
    %{number: 22, name: "Elías David Torres", surname: "Torres", position: "Delantero"},
    %{number: 23, name: "Nazareno Colombo", surname: "Colombo", position: "Defensor"},
    %{number: 24, name: "Adrián Marcos Fernández", surname: "Fernández", position: "Mediocampista"},
    %{number: 25, name: "Facundo Nicolás Cambeses", surname: "Cambeses", position: "Arquero"},
    %{number: 28, name: "Santiago Germán Solari", surname: "Solari", position: "Delantero"},
    %{number: 30, name: "Matías Nicolás Tagliamonte", surname: "Tagliamonte", position: "Arquero"},
    %{number: 32, name: "Lautaro Ariel Diaz", surname: "Diaz", position: "Delantero"},
    %{number: 34, name: "Tobías Javier Rubio", surname: "Rubio", position: "Defensor"},
    # Squad/youth players not on the first-team page and absent from Sofascore's
    # team feed — kept here on request. Positions are best-effort; correct in
    # place if wrong.
    %{number: 37, name: "Santino Aguirre", surname: "Aguirre", position: "Mediocampista"},
    %{number: 43, name: "Gonzalo Escudero", surname: "Escudero", position: "Defensor"},
    %{number: 46, name: "Alejandro Tello", surname: "Tello", position: "Mediocampista"},
    %{number: 58, name: "Tomás Pérez", surname: "Pérez", position: "Delantero"}
  ]

  @doc "The official squad, ordered by shirt number."
  def players, do: @players
end
