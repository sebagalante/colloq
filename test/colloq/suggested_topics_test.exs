defmodule Colloq.SuggestedTopicsTest do
  use Colloq.DataCase

  import Colloq.Factory

  alias Colloq.Forum
  alias Colloq.Repo

  defp tag_topic(topic, tag_id) do
    Repo.insert_all("topic_tags", [%{topic_id: topic.id, tag_id: tag_id}])
    topic
  end

  defp insert_tag(name) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        "tags",
        [
          %{
            name: name,
            slug: name,
            topic_count: 0,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        returning: [:id]
      )

    id
  end

  defp ids(topics), do: Enum.map(topics, & &1.id)

  setup do
    category = insert(:category)
    topic = insert(:topic, category: category)
    %{category: category, topic: topic}
  end

  test "suggests other topics in the same category", ctx do
    sibling = insert(:topic, category: ctx.category)

    assert ids(Forum.suggested_topics(ctx.topic, nil)) == [sibling.id]
  end

  test "never suggests the topic itself", ctx do
    assert Forum.suggested_topics(ctx.topic, nil) == []
  end

  test "excludes deleted topics", ctx do
    insert(:topic, category: ctx.category, deleted_at: DateTime.utc_now())

    assert Forum.suggested_topics(ctx.topic, nil) == []
  end

  test "suggests a tag match from a different category", ctx do
    tag = insert_tag("racing")
    tag_topic(ctx.topic, tag)
    other = insert(:topic, category: insert(:category)) |> tag_topic(tag)

    assert ids(Forum.suggested_topics(ctx.topic, nil)) == [other.id]
  end

  test "ranks more shared tags above a category-only match", ctx do
    [a, b] = [insert_tag("tag-a"), insert_tag("tag-b")]
    ctx.topic |> tag_topic(a) |> tag_topic(b)

    # Same category, no tags in common.
    category_only = insert(:topic, category: ctx.category)
    # Different category, both tags shared — should outrank the above.
    two_tags = insert(:topic, category: insert(:category)) |> tag_topic(a) |> tag_topic(b)

    assert ids(Forum.suggested_topics(ctx.topic, nil)) == [two_tags.id, category_only.id]
  end

  test "hides topics in read-restricted categories from non-staff", ctx do
    restricted = insert(:category, read_restricted: true)
    tag = insert_tag("shared")
    tag_topic(ctx.topic, tag)
    insert(:topic, category: restricted) |> tag_topic(tag)

    assert Forum.suggested_topics(ctx.topic, nil) == []
  end

  test "honours the limit", ctx do
    for _ <- 1..4, do: insert(:topic, category: ctx.category)

    assert length(Forum.suggested_topics(ctx.topic, nil, 2)) == 2
  end
end
