defmodule Colloq.Slug do
  @moduledoc """
  URL slug generation.

  Accent-aware on purpose: a naive `[^a-z0-9]` strip turns "Política" into
  `poltica` and "Fútbol" into `ftbol`, which is wrong for a Spanish-language
  forum. Latin letters are decomposed to their base form first (NFD), so the
  accent is dropped as a separate combining mark and the letter survives.
  """

  @default_max 60

  @doc """
  Builds a slug from arbitrary text.

  Returns `nil` when there's nothing usable left, so callers can decide on a
  fallback rather than silently storing an empty slug.

      iex> Colloq.Slug.slugify("Política y Sociedad")
      "politica-y-sociedad"

      iex> Colloq.Slug.slugify("  El Club  ")
      "el-club"

      iex> Colloq.Slug.slugify("Fútbol Argentino")
      "futbol-argentino"

      iex> Colloq.Slug.slugify("¿Qué onda?")
      "que-onda"

      iex> Colloq.Slug.slugify("!!!")
      nil
  """
  def slugify(text, max \\ @default_max)

  def slugify(text, max) when is_binary(text) do
    text
    # NFD splits "í" into "i" + combining acute; the next step drops the mark.
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
    |> String.downcase()
    # ñ survives NFD as its own codepoint in some inputs — map it explicitly.
    |> String.replace("ñ", "n")
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, max)
    |> String.trim("-")
    |> case do
      "" -> nil
      slug -> slug
    end
  end

  def slugify(_, _), do: nil
end
