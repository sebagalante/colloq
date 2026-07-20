defmodule Colloq.SlugTest do
  # Pure module — no Repo, so no DataCase and no sandbox.
  use ExUnit.Case, async: true
  doctest Colloq.Slug

  alias Colloq.Slug

  describe "slugify/2" do
    test "lowercases and hyphenates" do
      assert Slug.slugify("El Club") == "el-club"
      assert Slug.slugify("Competencias y Partidos") == "competencias-y-partidos"
    end

    test "strips Spanish accents rather than the letters carrying them" do
      assert Slug.slugify("Política") == "politica"
      assert Slug.slugify("Fútbol") == "futbol"
      assert Slug.slugify("Ñandú") == "nandu"
      assert Slug.slugify("Año") == "ano"
    end

    test "collapses runs of punctuation and whitespace into one hyphen" do
      assert Slug.slugify("Racing   ---   Club") == "racing-club"
      assert Slug.slugify("¿Qué onda?") == "que-onda"
    end

    test "trims leading and trailing separators" do
      assert Slug.slugify("  -- Off-Topic -- ") == "off-topic"
    end

    test "keeps an already-valid slug unchanged" do
      assert Slug.slugify("futbol-argentino") == "futbol-argentino"
    end

    test "returns nil when nothing usable survives" do
      assert Slug.slugify("!!!") == nil
      assert Slug.slugify("   ") == nil
      assert Slug.slugify("") == nil
      assert Slug.slugify(nil) == nil
    end

    test "truncates without leaving a trailing hyphen" do
      # Cutting "aaaa-bbbb" at 5 would leave "aaaa-"; the trim must run after.
      assert Slug.slugify("aaaa bbbb", 5) == "aaaa"
    end
  end
end
