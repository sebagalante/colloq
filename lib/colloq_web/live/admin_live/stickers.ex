defmodule ColloqWeb.AdminLive.Stickers do
  @moduledoc """
  Admin management of stickers: create packs, upload sticker images into a
  pack, list and delete. Stickers work in chat and inside posts. Static or
  animated (PNG/GIF/WebP/APNG).
  """
  use ColloqWeb, :live_view

  alias Colloq.Stickers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Stickers"))
      |> assign(:pack_name, "")
      |> assign(:selected_pack_id, nil)
      |> assign(:error, nil)
      |> load_packs()
      # Raster (.gif/.webp/.apng animate natively in an <img>) plus Lottie
      # vector stickers (.json, and .tgs = gzipped Lottie, Telegram's format).
      |> allow_upload(:image,
        accept: ~w(.png .gif .webp .apng .json .tgs),
        max_entries: 20,
        max_file_size: 2_000_000
      )

    {:ok, socket}
  end

  defp load_packs(socket) do
    packs = Stickers.list_packs_with_stickers()

    selected =
      cond do
        socket.assigns[:selected_pack_id] &&
            Enum.any?(packs, &(&1.id == socket.assigns.selected_pack_id)) ->
          socket.assigns.selected_pack_id

        packs != [] ->
          hd(packs).id

        true ->
          nil
      end

    socket
    |> assign(:packs, packs)
    |> assign(:selected_pack_id, selected)
  end

  @impl true
  def handle_event("validate", %{"pack_name" => name}, socket) do
    {:noreply, assign(socket, :pack_name, name)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("create-pack", %{"pack_name" => name}, socket) do
    case Stickers.create_pack(%{"name" => name, "created_by_id" => socket.assigns.current_user.id}) do
      {:ok, pack} ->
        {:noreply,
         socket
         |> assign(:pack_name, "")
         |> assign(:selected_pack_id, pack.id)
         |> assign(:error, nil)
         |> load_packs()
         |> put_flash(:info, gettext("Pack created."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, changeset_error(changeset))}
    end
  end

  def handle_event("select-pack", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_pack_id, String.to_integer(id))}
  end

  def handle_event("delete-pack", %{"id" => id}, socket) do
    pack = Stickers.get_pack!(String.to_integer(id))
    {:ok, _} = Stickers.delete_pack(pack)

    {:noreply,
     socket
     |> assign(:selected_pack_id, nil)
     |> load_packs()
     |> put_flash(:info, gettext("Pack deleted."))}
  end

  def handle_event("save", _params, socket) do
    pack_id = socket.assigns.selected_pack_id

    if is_nil(pack_id) do
      {:noreply, assign(socket, :error, gettext("Create or pick a pack first."))}
    else
      uploaded =
        consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
          ext = Path.extname(entry.client_name)
          filename = "sticker_#{System.unique_integer([:positive])}#{ext}"
          data = File.read!(path)

          case Colloq.Media.upload(data, filename: filename, content_type: entry.client_type) do
            {:ok, %{url: url}} -> {:ok, url}
            {:error, reason} -> {:postpone, {:error, reason}}
          end
        end)

      urls = Enum.filter(uploaded, &is_binary/1)

      Enum.each(urls, fn url ->
        Stickers.create_sticker(%{"image_url" => url, "pack_id" => pack_id})
      end)

      socket =
        case urls do
          [] ->
            assign(socket, :error, gettext("Please choose at least one image."))

          _ ->
            socket
            |> assign(:error, nil)
            |> load_packs()
            |> put_flash(:info, gettext("%{count} sticker(s) added.", count: length(urls)))
        end

      {:noreply, socket}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("delete-sticker", %{"id" => id}, socket) do
    sticker = Stickers.get_sticker!(String.to_integer(id))
    {:ok, _} = Stickers.delete_sticker(sticker)

    {:noreply,
     socket
     |> load_packs()
     |> put_flash(:info, gettext("Sticker removed."))}
  end

  def selected_pack(assigns) do
    Enum.find(assigns.packs, &(&1.id == assigns.selected_pack_id))
  end

  def friendly_upload_error(:too_large), do: gettext("Image is too large (max 2 MB).")
  def friendly_upload_error(:not_accepted), do: gettext("Unsupported file type.")
  def friendly_upload_error(:too_many_files), do: gettext("Up to 20 images at a time.")
  def friendly_upload_error(_), do: gettext("Upload error.")

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end
end
