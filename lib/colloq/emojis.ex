defmodule Colloq.Emojis do
  @moduledoc """
  Custom emoji management.

  Custom emoji are admin-uploaded images referenced as `:name:`. They can be
  used inside post bodies and as reactions. A cached name → image_url map is
  used at render time; it is invalidated whenever an emoji is added or removed.
  """
  import Ecto.Query
  alias Colloq.Repo
  alias Colloq.Emojis.CustomEmoji

  @cache :forum_cache
  @cache_key "custom_emojis_map"

  @doc "All custom emoji, newest first."
  def list_custom_emojis do
    Repo.all(from e in CustomEmoji, order_by: [desc: e.inserted_at])
  end

  def get_custom_emoji!(id), do: Repo.get!(CustomEmoji, id)

  @doc "Create a custom emoji and invalidate the render cache."
  def create_custom_emoji(attrs) do
    %CustomEmoji{}
    |> CustomEmoji.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&bust_cache/0)
  end

  @doc "Delete a custom emoji and invalidate the render cache."
  def delete_custom_emoji(%CustomEmoji{} = emoji) do
    emoji
    |> Repo.delete()
    |> tap_ok(&bust_cache/0)
  end

  @doc """
  A `%{"name" => "image_url"}` map of every custom emoji, cached for fast
  render-time lookups.
  """
  def map do
    case Cachex.get(@cache, @cache_key) do
      {:ok, nil} ->
        m = Map.new(list_custom_emojis(), &{&1.name, &1.image_url})
        Cachex.put(@cache, @cache_key, m)
        m

      {:ok, m} ->
        m

      _ ->
        Map.new(list_custom_emojis(), &{&1.name, &1.image_url})
    end
  end

  @doc """
  Replace `:name:` tokens in already-sanitized HTML with inline emoji images.

  Only known custom emoji are replaced; unknown `:tokens:` are left untouched.
  The name charset is validated on creation, so the injected markup is safe.
  """
  def render_shortcodes(html, custom_map \\ nil) when is_binary(html) do
    custom_map = custom_map || map()

    if custom_map == %{} do
      html
    else
      Regex.replace(~r/:([a-z0-9_]+):/, html, fn whole, name ->
        case Map.get(custom_map, name) do
          nil -> whole
          url -> img_tag(name, url)
        end
      end)
    end
  end

  @doc "HTML for a single custom emoji, or nil if the shortcode is unknown."
  def shortcode_img(":" <> _ = shortcode, custom_map \\ nil) do
    custom_map = custom_map || map()

    case Regex.run(~r/^:([a-z0-9_]+):$/, shortcode) do
      [_, name] ->
        case Map.get(custom_map, name) do
          nil -> nil
          url -> img_tag(name, url)
        end

      _ ->
        nil
    end
  end

  def shortcode_img(_, _custom_map), do: nil

  defp img_tag(name, url) do
    ~s(<img class="inline-emoji" src="#{url}" alt=":#{name}:" title=":#{name}:" loading="lazy" />)
  end

  defp bust_cache, do: Cachex.del(@cache, @cache_key)

  defp tap_ok({:ok, _} = res, fun) do
    fun.()
    res
  end

  defp tap_ok(res, _fun), do: res
end
