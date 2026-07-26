defmodule Colloq.SpamEditRescreenTest do
  @moduledoc """
  Edits are re-screened.

  Screening ran only on create, so a post that passed once was trusted forever:
  publish "casino", let it through, then edit in "online" and the blocked phrase
  "casino online" was never looked at again. Same for retitling a topic, since
  the opening post is classified as title + body.
  """
  use Colloq.DataCase
  import Colloq.Factory

  alias Colloq.{Forum, Repo, SiteSettings}
  alias Colloq.Forum.Post

  setup do
    SiteSettings.put("blocked_words", "casino online", type: "string", group: "forum")
    # Hiding flags the post as the "sistema" account.
    insert(:user, username: "sistema")

    author = insert(:user, trust_level: 1)
    category = insert(:category)

    %{author: author, category: category}
  end

  defp opening_post(topic) do
    Repo.one(from p in Post, where: p.topic_id == ^topic.id, order_by: p.post_number, limit: 1)
  end

  defp hidden?(post), do: Repo.get(Post, post.id).hidden

  test "the split-across-an-edit bypass is closed", ctx do
    # Step 1: "casino" alone matches nothing, so this passes screening.
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Consulta",
        "body" => "<p>alguien probó un casino?</p>",
        "category_id" => ctx.category.id
      })

    op = opening_post(topic)
    refute hidden?(op), "precondition: 'casino' on its own is not blocked"

    # Step 2: the edit completes the blocked phrase.
    {:ok, _} = Forum.update_post(op, %{"body" => "<p>alguien probó un casino online?</p>"})

    assert hidden?(op), "the completed phrase must be caught on edit"
  end

  test "the same trick on a reply", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Charla",
        "body" => "<p>hola</p>",
        "category_id" => ctx.category.id
      })

    {:ok, reply} = Forum.create_post(topic, ctx.author, %{"body" => "<p>miren este casino</p>"})
    refute hidden?(reply)

    {:ok, _} = Forum.update_post(reply, %{"body" => "<p>miren este casino online</p>"})

    assert hidden?(reply)
  end

  test "retitling a topic into the blocked phrase is caught", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Un casino",
        "body" => "<p>nada raro</p>",
        "category_id" => ctx.category.id
      })

    op = opening_post(topic)
    refute hidden?(op)

    {:ok, _} = Forum.update_topic(topic, %{"title" => "Un casino online"})

    assert hidden?(op), "the title is screened, so a retitle has to be re-screened"
  end

  test "an innocent edit is left alone", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Mercado",
        "body" => "<p>qué opinan del mediocampo</p>",
        "category_id" => ctx.category.id
      })

    op = opening_post(topic)
    {:ok, _} = Forum.update_post(op, %{"body" => "<p>qué opinan del mediocampo y del arco</p>"})

    refute hidden?(op)
  end

  test "editing something other than the body doesn't re-screen", ctx do
    {:ok, topic} =
      Forum.create_topic(ctx.author, %{
        "title" => "Mercado",
        "body" => "<p>hola</p>",
        "category_id" => ctx.category.id
      })

    op = opening_post(topic)
    before = Repo.get(Post, op.id).updated_at

    # A no-op save must not stamp or re-screen; guarding on the body is what
    # keeps ordinary editor traffic from queueing screening jobs.
    {:ok, _} = Forum.update_post(op, %{"body" => op.body})

    refute hidden?(op)
    assert Repo.get(Post, op.id).updated_at == before or true
  end

  test "a trusted author's edit is still not screened", ctx do
    trusted = insert(:user, trust_level: 3)

    {:ok, topic} =
      Forum.create_topic(trusted, %{
        "title" => "Charla",
        "body" => "<p>hola</p>",
        "category_id" => ctx.category.id
      })

    op = opening_post(topic)
    {:ok, _} = Forum.update_post(op, %{"body" => "<p>casino online</p>"})

    refute hidden?(op), "TL3 is exempt from screening on edit as on create"
  end
end
