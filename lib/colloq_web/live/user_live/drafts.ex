defmodule ColloqWeb.UserLive.Drafts do
  @moduledoc """
  "My drafts" — every unsent composer body this user is holding.

  Editing a draft is just opening its topic: the reply composer restores the
  saved body on mount (see `ColloqWeb.ForumLive.Topic`), so this page needs no
  editor of its own.
  """
  use ColloqWeb, :live_view

  alias Colloq.Forum
  alias Colloq.Accounts

  @impl true
  def mount(_params, session, socket) do
    case session["user_id"] do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(user_id)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:drafts, Forum.list_drafts(user_id))
          |> assign(:page_title, gettext("My drafts"))

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("delete-draft", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    Forum.delete_draft_by_id(user.id, String.to_integer(draft_id))

    {:noreply,
     socket
     |> assign(:drafts, Forum.list_drafts(user.id))
     |> put_flash(:info, gettext("Draft deleted."))}
  end

  # First line of the body, for the row's preview. Drafts are composer HTML.
  def draft_excerpt(nil), do: ""

  def draft_excerpt(body) do
    body
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  @doc """
  Where a draft row goes: straight to the composer holding it.

  Two parts, and both are needed:

    * `#reply-composer` — the topic's AutoScroll hook re-jumps to the unread
      divider (or the bottom) while layout settles, which overrode a plain
      scroll. A URL fragment is the one thing it stands down for, so this is
      what actually lands the page on the composer.
    * `?draft=1` — makes the server push `tiptap:focus`, putting the cursor at
      the end of the restored text.
  """
  def draft_path(%{topic_id: nil}), do: ~p"/forum/new"
  def draft_path(%{topic_id: topic_id}), do: ~p"/t/#{topic_id}?draft=1#reply-composer"

  def draft_title(%{topic: %{title: title}}) when is_binary(title), do: title
  def draft_title(%{title: title}) when is_binary(title) and title != "", do: title
  def draft_title(_), do: gettext("Untitled draft")
end
