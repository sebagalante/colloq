defmodule ColloqWeb.MentionController do
  @moduledoc """
  User search for @mention autocomplete in the composer.

  Returns a small JSON list of users matching a username/display-name prefix.
  """
  use ColloqWeb, :controller

  def search(conn, params) do
    query = params["q"] || ""
    users = Colloq.Accounts.search_users_for_mention(query)
    json(conn, %{users: users})
  end

  @doc "Search tags for the tag picker (popular tags when the query is empty)."
  def tags(conn, params) do
    query = String.trim(params["q"] || "")

    tags =
      case query do
        "" -> Colloq.Tags.list_tags() |> Enum.take(10)
        q -> Colloq.Tags.search_tags(q)
      end
      |> Enum.map(&%{name: &1.name, count: &1.topic_count, color: &1.color})

    json(conn, %{tags: tags})
  end

  @doc "List custom emoji for the composer picker."
  def emojis(conn, _params) do
    emojis =
      Colloq.Emojis.list_custom_emojis()
      |> Enum.map(&%{name: &1.name, url: &1.image_url})

    json(conn, %{emojis: emojis})
  end

  @doc "Sticker packs (with their stickers) for the sticker tray."
  def stickers(conn, _params) do
    json(conn, %{packs: Colloq.Stickers.tray()})
  end
end
