defmodule ColloqWeb.UserLive.Bookmarks do
  use ColloqWeb, :live_view

  alias Colloq.Bookmarks
  alias Colloq.Accounts

  @impl true
  def mount(_params, session, socket) do
    case session["user_id"] do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(user_id)
        bookmarks = Bookmarks.list_user_bookmarks(user_id)

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:bookmarks, bookmarks)
          |> assign(:page_title, gettext("Bookmarks"))

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("remove-bookmark", %{"bookmark_id" => bookmark_id}, socket) do
    bookmark = Enum.find(socket.assigns.bookmarks, &(&1.id == String.to_integer(bookmark_id)))

    if bookmark do
      Colloq.Repo.delete(bookmark)
      bookmarks = Bookmarks.list_user_bookmarks(socket.assigns.current_user.id)
      {:noreply, assign(socket, :bookmarks, bookmarks)}
    else
      {:noreply, socket}
    end
  end

  defp post_excerpt(nil), do: ""
  defp post_excerpt(post) do
    post.body
    |> HtmlSanitizeEx.strip_tags()
    |> String.slice(0, 150)
  end
end
