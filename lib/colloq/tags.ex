defmodule Colloq.Tags do
  @moduledoc """
  Tags context: manage tags for topics.

  Tags help categorize topics beyond the category system.
  Users can add tags when creating or editing topics.
  Tags are searchable and filterable.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Forum.Tag

  @doc """
  Lists all tags ordered by topic count (most used first).
  """
  def list_tags do
    Tag
    |> order_by(desc: :topic_count)
    |> Repo.all()
  end

  @doc """
  Gets a tag by ID.
  """
  def get_tag!(id), do: Repo.get!(Tag, id)

  @doc """
  Gets a tag by slug.
  """
  def get_tag_by_slug(slug), do: Repo.get_by(Tag, slug: slug)

  @doc """
  Creates a tag.
  """
  def create_tag(attrs) do
    %Tag{}
    |> Tag.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a tag.
  """
  def update_tag(%Tag{} = tag, attrs) do
    tag
    |> Tag.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a tag. Removes all topic associations first.
  """
  def delete_tag(%Tag{} = tag) do
    from(tt in "topic_tags", where: tt.tag_id == ^tag.id)
    |> Repo.delete_all()

    Repo.delete(tag)
  end

  @doc """
  Searches tags by name (ILIKE).
  """
  def search_tags(query) when is_binary(query) and query != "" do
    search_term = "%#{query}%"

    Tag
    |> where([t], ilike(t.name, ^search_term))
    |> order_by(desc: :topic_count)
    |> limit(10)
    |> Repo.all()
  end

  def search_tags(_), do: []

  @doc """
  Finds or creates tags by a list of names.
  Returns a list of Tag structs.
  """
  def find_or_create_tags(tag_names) when is_list(tag_names) do
    Enum.map(tag_names, fn name ->
      name = String.trim(name)
      slug = slugify(name)

      case Repo.get_by(Tag, slug: slug) do
        nil ->
          case create_tag(%{name: name}) do
            {:ok, tag} -> tag
            {:error, _} -> Repo.get_by!(Tag, slug: slug)
          end

        tag ->
          tag
      end
    end)
  end

  @doc """
  Sets tags on a topic. Replaces existing tags.
  Accepts a list of Tag structs.
  """
  def set_topic_tags(topic, tags) do
    topic = Repo.preload(topic, :tags)

    # Update topic_count for removed tags
    old_tag_ids = Enum.map(topic.tags, & &1.id) -- Enum.map(tags, & &1.id)
    if old_tag_ids != [] do
      from(t in Tag, where: t.id in ^old_tag_ids)
      |> Repo.update_all(inc: [topic_count: -1])
    end

    # Update topic_count for new tags
    new_tag_ids = Enum.map(tags, & &1.id) -- Enum.map(topic.tags, & &1.id)
    if new_tag_ids != [] do
      from(t in Tag, where: t.id in ^new_tag_ids)
      |> Repo.update_all(inc: [topic_count: 1])
    end

    topic
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.update()
  end

  @doc """
  Gets all tags for a topic.
  """
  def get_topic_tags(topic_id) do
    from(t in Tag,
      join: tt in "topic_tags", on: tt.tag_id == t.id,
      where: tt.topic_id == ^topic_id,
      order_by: t.name
    )
    |> Repo.all()
  end

  @doc """
  Preloads tags for a list of topics.
  Returns a map of topic_id => [Tag].
  """
  def preload_topic_tags(topic_ids) do
    tags_by_topic =
      from(t in Tag,
        join: tt in "topic_tags", on: tt.tag_id == t.id,
        where: tt.topic_id in ^topic_ids,
        order_by: t.name,
        select: {tt.topic_id, t}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    tags_by_topic
  end

  @doc """
  Lists topics with a specific tag.
  """
  def list_topics_by_tag(tag_id, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)

    from(topic in Colloq.Forum.Topic,
      join: tt in "topic_tags", on: tt.topic_id == topic.id,
      where: tt.tag_id == ^tag_id,
      order_by: [desc: topic.inserted_at],
      preload: [:user, :category, :last_post]
    )
    |> Colloq.Pagination.paginate(page, per_page)
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end
end
