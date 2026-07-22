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

  # Soft pastel palette (Tailwind ~300s) for tags without a custom color. A
  # tag's name maps to a stable entry, so the same name always gets the same
  # color. Pastels are light, so render tag chips with dark text.
  @palette ~w(#93c5fd #7dd3fc #6ee7b7 #86efac #fcd34d #fdba74 #fca5a5 #f9a8d4 #d8b4fe #c4b5fd #a5b4fc #5eead4)
  @default_color "#6b7280"

  @doc "Text color to pair with a tag chip background (dark, for the pastels)."
  def text_color, do: "#1f2937"

  @doc """
  Display color for a tag: its custom color if set, otherwise a stable one
  derived from its name (so tags without an explicit color still look distinct).
  """
  def color(%{color: color}) when is_binary(color) and color not in ["", @default_color],
    do: color

  def color(%{name: name}) when is_binary(name) do
    # md5 avalanches well even for short, similar tag names.
    idx =
      :crypto.hash(:md5, name)
      |> binary_part(0, 4)
      |> :binary.decode_unsigned()
      |> rem(length(@palette))

    Enum.at(@palette, idx)
  end

  def color(_), do: @default_color

  @doc """
  Lists all tags ordered by topic count (most used first), name breaking ties.

  The name tiebreaker matters more than it looks: most tags sit at a count of
  one, and without it Postgres is free to return equal rows in any order — so
  the tail of the list would appear to shuffle itself between page loads.
  """
  def list_tags do
    Tag
    # Synonyms are an alias for another tag, not a destination: listing them
    # would show two entries leading to the same topics.
    |> where([t], is_nil(t.synonym_of_id))
    |> order_by(desc: :topic_count, asc: :name)
    |> Repo.all()
  end

  @doc "Every tag including synonyms, for the admin screen."
  def list_tags_with_synonyms do
    Tag
    |> order_by(desc: :topic_count, asc: :name)
    |> preload(:synonym_of)
    |> Repo.all()
  end

  @doc """
  The most-used tags, for the sidebar. Tags with no topics are skipped — an
  unused tag is noise in a nav list, and `topic_count` is kept current by
  `set_topic_tags/2`.
  """
  def popular_tags(limit \\ 12) do
    Tag
    |> where([t], t.topic_count > 0 and is_nil(t.synonym_of_id))
    |> order_by(desc: :topic_count, asc: :name)
    |> limit(^limit)
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
  Finds or creates tags by a list of names. Returns a list of Tag structs.

  Options:
    * `:create` — materialise unknown tags (default `true`)
    * `:limit`  — cap how many tags are applied: an integer, or `:unlimited`
      (default). Extra tags beyond the cap are dropped. Use `tag_limit/1` to
      derive the per-user cap.
  """
  def find_or_create_tags(tag_names, opts \\ []) when is_list(tag_names) do
    create? = Keyword.get(opts, :create, true)

    tag_names
    |> take_limit(Keyword.get(opts, :limit, :unlimited))
    |> Enum.map(fn name ->
      name = String.trim(name)
      slug = slugify(name)

      case Repo.get_by(Tag, slug: slug) do
        nil ->
          # Unknown tag: only materialise it when the caller is allowed to
          # create new tags. Otherwise it's silently dropped (existing tags
          # still apply).
          if create? do
            case create_tag(%{name: name}) do
              {:ok, tag} -> tag
              {:error, _} -> Repo.get_by(Tag, slug: slug)
            end
          end

        tag ->
          tag
      end
    end)
    |> Enum.reject(&is_nil/1)
    # Applying a synonym stores the canonical tag instead, which is the whole
    # point: the two spellings stop competing for the same topics.
    |> Enum.map(&resolve/1)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  The canonical tag behind a possible synonym.

  Follows one hop only. Chains (a -> b -> c) are prevented at write time by
  `make_synonym/2`, and stopping here means a cycle introduced by hand can
  never hang a request.
  """
  def resolve(%Tag{synonym_of_id: nil} = tag), do: tag

  def resolve(%Tag{synonym_of_id: id}) do
    case Repo.get(Tag, id) do
      nil -> Repo.get!(Tag, id)
      %Tag{} = canonical -> canonical
    end
  end

  def resolve(other), do: other

  @doc """
  Points `tag` at `canonical` and moves every topic across.

  Existing topics are re-tagged rather than left behind — otherwise merging two
  tags would hide the synonym's topics from both. `topic_count` is recomputed
  from the join table afterwards, since topics tagged with both would otherwise
  be double counted.

  Refuses to build a chain or a cycle: the target must not itself be a synonym,
  and a tag with its own synonyms cannot become one.
  """
  def make_synonym(%Tag{} = tag, %Tag{} = canonical) do
    cond do
      tag.id == canonical.id ->
        {:error, :self}

      canonical.synonym_of_id != nil ->
        {:error, :target_is_synonym}

      Repo.exists?(from t in Tag, where: t.synonym_of_id == ^tag.id) ->
        {:error, :has_synonyms}

      true ->
        Repo.transaction(fn ->
          move_topics(tag, canonical)

          {:ok, updated} =
            tag |> Ecto.Changeset.change(synonym_of_id: canonical.id) |> Repo.update()

          recount([tag.id, canonical.id])
          updated
        end)
    end
  end

  @doc "Turns a synonym back into an independent tag. Topics are not moved back."
  def unmake_synonym(%Tag{} = tag) do
    tag |> Ecto.Changeset.change(synonym_of_id: nil) |> Repo.update()
  end

  # Re-point topic_tags rows at the canonical tag, skipping topics that already
  # carry it — the join table has a unique pair and would otherwise conflict.
  defp move_topics(tag, canonical) do
    Repo.query!(
      """
      UPDATE topic_tags SET tag_id = $2
      WHERE tag_id = $1
        AND topic_id NOT IN (SELECT topic_id FROM topic_tags WHERE tag_id = $2)
      """,
      [tag.id, canonical.id]
    )

    # Whatever is left is a topic that had both tags; drop the duplicate.
    Repo.query!("DELETE FROM topic_tags WHERE tag_id = $1", [tag.id])
  end

  defp recount(tag_ids) do
    Repo.query!(
      """
      UPDATE tags SET topic_count = COALESCE((
        SELECT COUNT(*) FROM topic_tags WHERE topic_tags.tag_id = tags.id
      ), 0)
      WHERE id = ANY($1)
      """,
      [tag_ids]
    )
  end

  defp take_limit(names, :unlimited), do: names
  defp take_limit(names, n) when is_integer(n) and n >= 0, do: Enum.take(names, n)
  defp take_limit(names, _), do: names

  @default_create_min_trust 1
  @default_max_tags_per_topic 5

  @doc """
  Minimum trust level required to create brand-new tags. Configurable via the
  `min_trust_to_create_tags` site setting; defaults to #{@default_create_min_trust}.
  """
  def create_min_trust do
    case Colloq.SiteSettings.get("min_trust_to_create_tags") do
      n when is_integer(n) -> n
      _ -> @default_create_min_trust
    end
  end

  @doc """
  Site-wide fallback cap, used only when a user has no usable trust level.
  Per-level caps live on `trust_levels.max_tags_per_topic`; this setting is the
  backstop, defaulting to #{@default_max_tags_per_topic}.
  """
  def max_per_topic do
    case Colloq.SiteSettings.get("max_tags_per_topic") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_tags_per_topic
    end
  end

  @doc """
  The tag cap for `user` when tagging a topic. Staff are `:unlimited`;
  everyone else gets their trust level's `max_tags_per_topic` (TL0 is `0` —
  no tagging at all). Logged-out visitors can't tag.
  """
  def tag_limit(%{role: role}) when role in ["moderator", "admin", "super_admin"], do: :unlimited

  def tag_limit(%{trust_level: tl}) when is_integer(tl), do: Colloq.Trust.max_tags_per_topic(tl)

  def tag_limit(_), do: 0

  @doc """
  The tag cap as a string for the `data-max-tags` attribute the TagInput hook
  reads: `""` (empty) means unlimited, otherwise the number.
  """
  def tag_limit_attr(user) do
    case tag_limit(user) do
      :unlimited -> ""
      n -> to_string(n)
    end
  end

  @doc """
  Whether a user may create new tags. Staff always can; everyone else must
  meet the configured trust-level threshold.
  """
  def can_create?(%{role: role}) when role in ["moderator", "admin", "super_admin"], do: true
  def can_create?(%{trust_level: tl}) when is_integer(tl), do: tl >= create_min_trust()
  def can_create?(_), do: false

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
      where: tt.tag_id == ^tag_id and is_nil(topic.deleted_at),
      order_by: [desc: topic.inserted_at],
      preload: [:user, :category, :last_post]
    )
    |> Colloq.Pagination.paginate(page: page, page_size: per_page)
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
