defmodule Colloq.Repo.Migrations.DecodeEntitiesInEmbedUrls do
  use Ecto.Migration

  @moduledoc """
  Repairs embed URLs that stored HTML entities instead of the characters.

  Post bodies are HTML, so a link written `?t=70&v=X` is saved as
  `?t=70&amp;v=X`. `EmbedWorker.extract_urls/1` scanned that markup directly
  and never decoded, so the stored URL pointed somewhere else entirely —
  YouTube received a parameter literally named `amp;v`, and the preview linked
  to a broken address.

  The extractor now decodes (`EmbedWorker.decode_entities/1`); this fixes the
  rows written before that.

  `&amp;` is replaced last so `&amp;lt;` becomes `&lt;` rather than `<`.
  """

  def up do
    for column <- ~w(url image_url) do
      execute("""
      UPDATE embeds
         SET #{column} = replace(replace(replace(replace(replace(replace(
               #{column},
               '&quot;', '"'),
               '&#39;',  ''''),
               '&lt;',   '<'),
               '&gt;',   '>'),
               '&#38;',  '&'),
               '&amp;',  '&')
       WHERE #{column} ~ '&(amp|#38|quot|lt|gt|#39);'
      """)
    end
  end

  def down do
    # Re-encoding would be guesswork — a legitimate "&" is indistinguishable
    # from one that came from "&amp;".
    :ok
  end
end
