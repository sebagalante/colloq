defmodule Colloq.Workers.MessageEmbedWorker do
  @moduledoc """
  Link unfurling for chat messages.

  Same job as `Colloq.Workers.EmbedWorker` does for posts, and it reuses that
  module's URL extraction and Open Graph fetching — only the storage and the
  "it's ready" broadcast differ.

  Two rules keep chat cards from getting noisy:

    * URLs that already render themselves (images, GIFs, video, YouTube, Spotify…)
      are skipped — the bubble embeds those inline, straight from the body, with
      no round trip;
    * one card per message, Telegram-style, even if the message carries several
      links.

  A link that can't be scraped produces no card at all. In a post the bare-host
  fallback still tells the reader where the link goes; in a chat bubble the URL
  is right there above it, so an empty card would be pure noise.
  """
  use Oban.Worker, queue: :media, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Messaging.{Message, MessageEmbed}
  alias Colloq.Workers.EmbedWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    with %Message{deleted_at: nil} = message <- Repo.get(Message, message_id),
         url when is_binary(url) <- preview_url(message.body),
         %{} = og <- EmbedWorker.fetch_embed(url) do
      insert_embed(message, url, og)
    else
      _ -> :ok
    end
  end

  @doc """
  The one URL in `body` worth a preview card, or nil.

  Public so the send path can decide whether a job is worth enqueuing at all —
  most messages have no link, and the check is the same one.
  """
  def preview_url(body) when is_binary(body) do
    inline = body |> ColloqWeb.ForumLive.Topic.body_embeds() |> Enum.map(& &1.url) |> MapSet.new()

    body
    |> EmbedWorker.extract_urls()
    |> Enum.reject(&MapSet.member?(inline, &1))
    |> List.first()
  end

  def preview_url(_), do: nil

  defp insert_embed(message, url, og) do
    attrs = %{
      message_id: message.id,
      url: url,
      host: URI.parse(url).host || url,
      title: present(og[:title]) || URI.parse(url).host || url,
      description: og[:description] || "",
      image_url: og[:image_url] || ""
    }

    # `on_conflict: :nothing` covers a retry landing after a successful attempt;
    # the unique index is on {message_id, url}.
    result =
      %MessageEmbed{}
      |> MessageEmbed.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:message_id, :url])

    case result do
      {:ok, _} ->
        # Both participants have the thread open on a "dm:<id>" subscription;
        # only the id travels, as with a new message.
        ColloqWeb.Endpoint.broadcast("dm:#{message.conversation_id}", "embed_ready", %{
          message_id: message.id
        })

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp present(s) when is_binary(s) and s != "", do: s
  defp present(_), do: nil
end
