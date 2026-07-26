defmodule ColloqWeb.BrandingTest do
  @moduledoc """
  The site_title / site_description / site_logo / site_favicon settings existed
  for a long time without a single reader, so changing them in the admin panel
  did nothing. These assert they actually reach the page.
  """
  use ColloqWeb.ConnCase

  alias Colloq.SiteSettings

  @endpoint ColloqWeb.Endpoint

  setup do
    SiteSettings.clear_branding_cache()
    on_exit(&SiteSettings.clear_branding_cache/0)
    :ok
  end

  defp set(key, value, type \\ "string"),
    do: SiteSettings.put(key, value, type: type, group: "general")

  test "site_title reaches the title tag and the header", %{conn: conn} do
    set("site_title", "ForoRacing")

    html = conn |> get("/") |> html_response(200)

    assert html =~ "ForoRacing"
    refute html =~ "◆</span> Colloq"
  end

  test "falls back to Colloq when site_title is unset" do
    assert SiteSettings.branding().title == "Colloq"
  end

  test "site_logo replaces the ◆ mark but never the site title", %{conn: conn} do
    set("site_title", "ForoRacing")
    set("site_logo", "https://example.test/logo.png", "image")

    html = conn |> get("/") |> html_response(200)

    assert html =~ "https://example.test/logo.png"
    # The name still shows next to the logo — hiding it was the bug.
    assert html =~ "ForoRacing"
    refute html =~ "text-accent\">◆"
  end

  test "site_favicon overrides the default icon", %{conn: conn} do
    set("site_favicon", "https://example.test/fav.png", "image")

    html = conn |> get("/") |> html_response(200)

    assert html =~ ~s(<link rel="icon" href="https://example.test/fav.png")
    refute html =~ ~s(href="/favicon.svg")
  end

  test "site_description becomes the meta and OG description", %{conn: conn} do
    set("site_description", "Comunidad de Racing")

    html = conn |> get("/") |> html_response(200)

    assert html =~ ~s(<meta name="description" content="Comunidad de Racing")
    assert html =~ ~s(property="og:description" content="Comunidad de Racing")
  end

  test "a blank value falls back instead of rendering empty chrome" do
    set("site_title", "")
    assert SiteSettings.branding().title == "Colloq"

    set("site_logo", "", "image")
    assert SiteSettings.branding().logo == nil
  end

  test "saving a setting invalidates the cache" do
    set("site_title", "Primero")
    assert SiteSettings.branding().title == "Primero"

    set("site_title", "Segundo")
    assert SiteSettings.branding().title == "Segundo"
  end
end
