defmodule Colloq.TagSynonymsTest do
  use Colloq.DataCase, async: false

  import Ecto.Query

  alias Colloq.Forum.Tag
  alias Colloq.{Repo, Tags}

  # Unique suffix per call: tag slugs are globally unique, so fixed names
  # collide with anything a previous test (or run) left behind. Match on :ok so
  # a failed insert fails the test instead of quietly returning a changeset.
  defp tag(name) do
    {:ok, tag} = Tags.create_tag(%{name: "#{name}-#{System.unique_integer([:positive])}"})
    tag
  end

  defp tagged_count(tag_id) do
    Repo.one(from tt in "topic_tags", where: tt.tag_id == ^tag_id, select: count())
  end

  defp topic!(n) do
    user = Repo.insert!(%Colloq.Accounts.User{
      email: "syn#{n}-#{System.unique_integer([:positive])}@test.com",
      username: "syn#{n}#{System.unique_integer([:positive])}",
      password_hash: "x"
    })

    category = Repo.insert!(%Colloq.Forum.Category{
      name: "Cat #{System.unique_integer([:positive])}",
      slug: "cat-#{System.unique_integer([:positive])}",
      position: 1
    })

    Repo.insert!(%Colloq.Forum.Topic{
      title: "Topic #{n} #{System.unique_integer([:positive])}",
      slug: "topic-#{System.unique_integer([:positive])}",
      user_id: user.id,
      category_id: category.id
    })
  end

  describe "make_synonym/2" do
    test "moves the synonym's topics onto the canonical tag" do
      canonical = tag("formula1")
      synonym = tag("f1")
      topic = topic!(1)

      Repo.insert_all("topic_tags", [%{topic_id: topic.id, tag_id: synonym.id}])

      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      assert tagged_count(synonym.id) == 0
      assert tagged_count(canonical.id) == 1
    end

    test "a topic carrying both tags ends up with one row, not a conflict" do
      # topic_tags has a unique (topic_id, tag_id) pair, so a naive UPDATE would
      # blow up here — this is the case that actually breaks a merge.
      canonical = tag("libertadores")
      synonym = tag("copa-libertadores")
      topic = topic!(2)

      Repo.insert_all("topic_tags", [
        %{topic_id: topic.id, tag_id: canonical.id},
        %{topic_id: topic.id, tag_id: synonym.id}
      ])

      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      assert tagged_count(canonical.id) == 1
      assert tagged_count(synonym.id) == 0
    end

    test "topic_count is recomputed, not incremented" do
      canonical = tag("racing")
      synonym = tag("academia")
      t1 = topic!(3)
      t2 = topic!(4)

      Repo.insert_all("topic_tags", [
        %{topic_id: t1.id, tag_id: synonym.id},
        %{topic_id: t2.id, tag_id: synonym.id},
        %{topic_id: t2.id, tag_id: canonical.id}
      ])

      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      assert Repo.get!(Tag, canonical.id).topic_count == 2
      assert Repo.get!(Tag, synonym.id).topic_count == 0
    end

    test "refuses to make a tag a synonym of itself" do
      t = tag("cine")
      assert {:error, :self} = Tags.make_synonym(t, t)
    end

    test "refuses to build a chain a -> b -> c" do
      a = tag("aa")
      b = tag("bb")
      c = tag("cc")

      assert {:ok, _} = Tags.make_synonym(b, c)
      # b is already a synonym, so nothing may point at it.
      assert {:error, :target_is_synonym} = Tags.make_synonym(a, Repo.get!(Tag, b.id))
    end

    test "a tag that already has synonyms cannot become one" do
      canonical = tag("dd")
      synonym = tag("ee")
      other = tag("ff")

      assert {:ok, _} = Tags.make_synonym(synonym, canonical)
      assert {:error, :has_synonyms} = Tags.make_synonym(canonical, other)
    end
  end

  describe "resolve/1 and tagging" do
    test "applying a synonym by name stores the canonical tag" do
      canonical = tag("bundesliga")
      synonym = tag("bundes")
      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      names =
        [synonym.name]
        |> Tags.find_or_create_tags(create: false)
        |> Enum.map(& &1.name)

      assert names == [canonical.name]
    end

    test "applying both names yields the canonical tag once" do
      canonical = tag("seleccion")
      synonym = tag("afa")
      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      tags = Tags.find_or_create_tags([synonym.name, canonical.name], create: false)

      assert length(tags) == 1
    end
  end

  describe "listings" do
    test "synonyms are hidden from the public tag list" do
      canonical = tag("gg")
      synonym = tag("hh")
      assert {:ok, _} = Tags.make_synonym(synonym, canonical)

      ids = Tags.list_tags() |> Enum.map(& &1.id)

      assert canonical.id in ids
      refute synonym.id in ids
    end
  end
end
