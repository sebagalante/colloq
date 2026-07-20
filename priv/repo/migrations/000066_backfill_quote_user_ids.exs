defmodule Colloq.Repo.Migrations.BackfillQuoteUserIds do
  @moduledoc """
  Adds `data-quote-user-id` to quotes created before that attribute existed, so
  the "collapse quotes from blocked users" feature works on historical posts too.

  Quote blocks are `<blockquote><p><strong>@handle:</strong></p>…`, so we can map
  the handle back to a user id reliably. Unknown handles are left untouched.
  """
  use Ecto.Migration
  import Ecto.Query

  def up do
    repo = repo()

    handle_to_id =
      repo.all(from u in "users", select: {u.username, u.id})
      |> Map.new()

    from(p in "posts",
      where: like(p.body, "%<blockquote>%") and not like(p.body, "%data-quote-user-id%"),
      select: {p.id, p.body}
    )
    |> repo.all()
    |> Enum.each(fn {id, body} ->
      new_body = inject_ids(body, handle_to_id)

      if new_body != body do
        repo.query!("UPDATE posts SET body = $1 WHERE id = $2", [new_body, id])
      end
    end)
  end

  def down, do: :ok

  defp inject_ids(body, handle_to_id) do
    Regex.replace(
      ~r/<blockquote>(\s*<p>\s*<strong>@([A-Za-z0-9_]+):)/i,
      body,
      fn full, rest, handle ->
        case Map.get(handle_to_id, handle) do
          nil -> full
          uid -> ~s(<blockquote data-quote-user-id="#{uid}">) <> rest
        end
      end
    )
  end
end
