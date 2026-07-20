defmodule Colloq.Repo.Migrations.NormalizeCategorySlugs do
  use Ecto.Migration

  @moduledoc """
  Rewrites category slugs that were stored as raw names.

  The admin form asks for the slug by hand and never normalised it, so five
  categories were saved with their name verbatim — spaces and capitals included
  — producing URLs like `/c/Competencias%20y%20Partidos`. `Category.changeset/2`
  now slugifies on write; this fixes the rows already in the table.

  Slugs are only ever resolved by lookup (`/c/:slug` → category), so rewriting
  them breaks nothing internally. **External links to the old URLs will 404** —
  there is no redirect table here, and with these five never having been
  shareable in a clean form, that is judged acceptable.

  `down/0` cannot restore the originals: the old value isn't recoverable from
  the new one. It is a no-op rather than a lie.
  """

  def up do
    # Mirrors Colloq.Slug.slugify/1: strip accents via NFD, lowercase, collapse
    # anything non-alphanumeric to single hyphens, trim. Written in SQL so the
    # migration doesn't depend on application code that may change later.
    execute("""
    UPDATE categories
       SET slug = trim(both '-' from
             regexp_replace(
               lower(
                 translate(
                   normalize(name, NFD),
                   'áàâäãéèêëíìîïóòôöõúùûüñçÁÀÂÄÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÑÇ',
                   'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC'
                 )
               ),
               '[^a-z0-9]+', '-', 'g'
             )
           )
     WHERE slug ~ '[^a-z0-9-]' OR slug ~ '[A-Z]'
    """)
  end

  def down do
    :ok
  end
end
