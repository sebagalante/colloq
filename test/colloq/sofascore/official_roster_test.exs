defmodule Colloq.Sofascore.OfficialRosterTest do
  use ExUnit.Case, async: true

  alias Colloq.Sofascore.OfficialRoster

  # Trimmed to the shape the club's page actually uses: one <li> per player
  # with the full name in the photo's alt, "Surname," in .nombre strong, and
  # .posicion / .numero spans. The surrounding page is menus and footer links,
  # which are <li>s too — hence the "ignores page furniture" test.
  defp li(number, name, surname, position) do
    """
    <li>
      <a href="/futbol/primer-equipo/plantel/jugador/#{number}_x/">
        <img class="lazyload" data-src="/img/x.webp" alt="#{name}" />
      </a>
      <div class="nombre">
        <div class="barrafx"></div>
        <a href="/futbol/primer-equipo/plantel/jugador/#{number}_x/">
          <strong>#{surname},</strong> given names\t\t\t
        </a>
        <span class="posicion">#{position}</span>
      </div>
      <span class="numero">#{number}</span>
    </li>
    """
  end

  # A plausible squad: enough players to clear the sanity floor, with a keeper.
  defp squad_html(extra \\ "") do
    outfield = for n <- 2..25, do: li(n, "Nombre Jugador#{n}", "Jugador#{n}", "Defensor")

    "<html><body><ul>" <>
      li(1, "Francisco Gómez", "Gómez", "Arquero") <>
      Enum.join(outfield) <> extra <> "</ul></body></html>"
  end

  describe "parse/1" do
    test "reads number, full name, surname and position off each player" do
      {:ok, players} = OfficialRoster.parse(squad_html())

      assert %{number: 1, name: "Francisco Gómez", surname: "Gómez", position: "Arquero"} =
               hd(players)

      assert length(players) == 25
    end

    test "returns players ordered by shirt number" do
      {:ok, players} = OfficialRoster.parse(squad_html())
      assert Enum.map(players, & &1.number) == Enum.sort(Enum.map(players, & &1.number))
    end

    test "collapses the page's tabs and double spaces out of names" do
      html = squad_html(li(30, "Matías  Nicolás\tTagliamonte", "Tagliamonte", "Arquero"))
      {:ok, players} = OfficialRoster.parse(html)

      assert %{name: "Matías Nicolás Tagliamonte"} = Enum.find(players, &(&1.number == 30))
    end

    test "ignores list items that are not players" do
      html = squad_html("<li><a href=\"/contacto\">Contacto</a></li>")
      {:ok, players} = OfficialRoster.parse(html)

      refute Enum.any?(players, &(&1.surname == ""))
      assert length(players) == 25
    end

    test "gives clashing surnames an initial, and leaves the rest alone" do
      html =
        squad_html(
          li(37, "Adrián Emmanuel Martínez", "Martínez", "Delantero") <>
            li(38, "Mateo Ezequiel Martínez", "Martínez", "Defensor")
        )

      {:ok, players} = OfficialRoster.parse(html)

      assert %{short: "A. Martínez"} = Enum.find(players, &(&1.number == 37))
      assert %{short: "M. Martínez"} = Enum.find(players, &(&1.number == 38))
      refute Map.has_key?(Enum.find(players, &(&1.number == 1)), :short)
    end

    test "refuses a squad too small to be real, so a markup change can't wipe the board" do
      html =
        "<html><body><ul>" <> li(1, "Francisco Gómez", "Gómez", "Arquero") <> "</ul></body></html>"

      assert {:error, {:implausible_squad, 1}} = OfficialRoster.parse(html)
    end

    test "refuses a squad with no goalkeeper" do
      html =
        "<html><body><ul>" <>
          Enum.join(for n <- 1..24, do: li(n, "Nombre J#{n}", "J#{n}", "Defensor")) <>
          "</ul></body></html>"

      assert {:error, :no_goalkeeper} = OfficialRoster.parse(html)
    end
  end
end
