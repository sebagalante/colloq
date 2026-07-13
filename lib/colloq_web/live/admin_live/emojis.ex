defmodule ColloqWeb.AdminLive.Emojis do
  @moduledoc """
  Admin management of custom emoji: upload an image, give it a `:name:`,
  list and delete. Custom emoji work both in posts and as reactions.
  """
  use ColloqWeb, :live_view

  alias Colloq.Emojis

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Custom emoji"))
      |> assign(:emojis, Emojis.list_custom_emojis())
      |> assign(:name, "")
      |> assign(:error, nil)
      |> allow_upload(:image,
        accept: ~w(.png .gif .webp .jpg .jpeg),
        max_entries: 1,
        max_file_size: 1_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"name" => name}, socket) do
    {:noreply, assign(socket, :name, name)}
  end

  def handle_event("save", %{"name" => name}, socket) do
    uploaded =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name)
        filename = "emoji_#{System.unique_integer([:positive])}#{ext}"
        data = File.read!(path)

        case Colloq.Media.upload(data, filename: filename, content_type: entry.client_type) do
          {:ok, %{url: url}} -> {:ok, url}
          {:error, reason} -> {:postpone, {:error, reason}}
        end
      end)

    case uploaded do
      [url] when is_binary(url) ->
        case Emojis.create_custom_emoji(%{"name" => name, "image_url" => url}) do
          {:ok, _emoji} ->
            {:noreply,
             socket
             |> assign(:emojis, Emojis.list_custom_emojis())
             |> assign(:name, "")
             |> assign(:error, nil)
             |> put_flash(:info, gettext("Emoji added."))}

          {:error, changeset} ->
            {:noreply, assign(socket, :error, changeset_error(changeset))}
        end

      _ ->
        {:noreply, assign(socket, :error, gettext("Please choose an image."))}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    emoji = Emojis.get_custom_emoji!(String.to_integer(id))
    {:ok, _} = Emojis.delete_custom_emoji(emoji)

    {:noreply,
     socket
     |> assign(:emojis, Emojis.list_custom_emojis())
     |> put_flash(:info, gettext("Emoji removed."))}
  end

  def friendly_upload_error(:too_large), do: gettext("Image is too large (max 1 MB).")
  def friendly_upload_error(:not_accepted), do: gettext("Unsupported file type.")
  def friendly_upload_error(:too_many_files), do: gettext("Only one image at a time.")
  def friendly_upload_error(_), do: gettext("Upload error.")

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end
end
