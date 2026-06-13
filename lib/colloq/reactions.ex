defmodule Colloq.Reactions do
  @moduledoc """
  Contexto de reacciones (emoji) a posts.

  Permite a los usuarios reaccionar con un emoji a cualquier post.
  Implementa toggle: si ya reaccionó con ese emoji, lo quita; si no, lo agrega.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Reactions.Reaction
  alias Colloq.Forum.Post

  @doc """
  Alterna una reacción (on/off) para un usuario en un post.

  Si el usuario ya reaccionó con ese emoji, se elimina la reacción.
  Si no existía, se crea. Respeta la restricción unique [post_id, user_id, emoji].

  Retorna {:ok, :added, reaction} o {:ok, :removed, nil}
  """
  def toggle_reaction(post_id, user_id, emoji) when is_binary(emoji) do
    existing =
      Reaction
      |> where(post_id: ^post_id, user_id: ^user_id, emoji: ^emoji)
      |> Repo.one()

    result =
      case existing do
        nil ->
          {:ok, reaction} =
            %Reaction{}
            |> Reaction.changeset(%{
              post_id: post_id,
              user_id: user_id,
              emoji: emoji
            })
            |> Repo.insert()

          {:ok, :added, reaction}

        reaction ->
          Repo.delete!(reaction)
          {:ok, :removed, nil}
      end

    # Actualizar contador en el post
    update_post_counter(post_id)

    # Broadcast para actualización en tiempo real
    counts = reaction_counts(post_id)
    ColloqWeb.Endpoint.broadcast("forum:topic:all", "reaction_updated", %{
      post_id: post_id,
      counts: counts
    })

    result
  rescue
    Ecto.ConstraintError -> {:error, :already_reacted}
  end

  @doc """
  Devuelve un mapa con el conteo de cada emoji para un post.

  ## Ejemplo
      iex> reaction_counts(42)
      %{"👍" => 5, "❤️" => 3}
  """
  def reaction_counts(post_id) do
    Reaction
    |> where([r], r.post_id == ^post_id)
    |> group_by([r], r.emoji)
    |> select([r], {r.emoji, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Devuelve la lista de usuarios que reaccionaron con un emoji específico.

  ## Ejemplo
      iex> who_reacted(42, "👍")
      [%User{username: "fulanito"}, ...]
  """
  def who_reacted(post_id, emoji) when is_binary(emoji) do
    Reaction
    |> where([r], r.post_id == ^post_id and r.emoji == ^emoji)
    |> preload(:user)
    |> Repo.all()
    |> Enum.map(& &1.user)
  end

  defp update_post_counter(post_id) do
    {count, _} =
      Reaction
      |> where([r], r.post_id == ^post_id)
      |> select([r], count(r.id))
      |> Repo.all()

    count = count |> List.first() |> elem(0)

    Post
    |> where(id: ^post_id)
    |> Repo.update_all(set: [reactions_count: count])
  end
end
