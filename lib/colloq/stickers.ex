defmodule Colloq.Stickers do
  @moduledoc """
  Sticker management. Stickers are admin-curated images organised into packs.
  They can be sent in chat (as a message attachment) and inserted into posts
  (as an inline image). Static or animated.
  """
  import Ecto.Query
  alias Colloq.Repo
  alias Colloq.Stickers.{Pack, Sticker}

  # --- Packs ---

  @doc "All packs, ordered for display, with their stickers preloaded."
  def list_packs_with_stickers do
    Repo.all(
      from p in Pack,
        order_by: [asc: p.position, asc: p.id],
        preload: [stickers: ^from(s in Sticker, order_by: [asc: s.position, asc: s.id])]
    )
  end

  @doc "All packs, ordered for display."
  def list_packs do
    Repo.all(from p in Pack, order_by: [asc: p.position, asc: p.id])
  end

  def get_pack!(id), do: Repo.get!(Pack, id)

  def create_pack(attrs) do
    %Pack{}
    |> Pack.changeset(attrs)
    |> Repo.insert()
  end

  def delete_pack(%Pack{} = pack), do: Repo.delete(pack)

  # --- Stickers ---

  def list_stickers(pack_id) do
    Repo.all(
      from s in Sticker,
        where: s.pack_id == ^pack_id,
        order_by: [asc: s.position, asc: s.id]
    )
  end

  def get_sticker!(id), do: Repo.get!(Sticker, id)

  def create_sticker(attrs) do
    %Sticker{}
    |> Sticker.changeset(attrs)
    |> Repo.insert()
  end

  def delete_sticker(%Sticker{} = sticker), do: Repo.delete(sticker)

  @doc """
  A tray-ready list: `[%{name, slug, stickers: [%{id, url}]}]`, only
  including packs that actually have stickers. Used by the `/api/stickers`
  feed the pickers consume.
  """
  def tray do
    list_packs_with_stickers()
    |> Enum.reject(&(&1.stickers == []))
    |> Enum.map(fn pack ->
      %{
        name: pack.name,
        slug: pack.slug,
        stickers: Enum.map(pack.stickers, &%{id: &1.id, url: &1.image_url})
      }
    end)
  end

  @doc "Whether a URL points at a known sticker (used to validate sends)."
  def sticker_url?(url) when is_binary(url) and url != "" do
    Repo.exists?(from s in Sticker, where: s.image_url == ^url)
  end

  def sticker_url?(_), do: false
end
