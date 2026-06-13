defmodule Colloq.Moderation do
  @moduledoc """
  Contexto de moderación del foro.

  Permite reportar posts, resolver reportes, ocultar posts y
  ejecutar moderación automática por palabras bloqueadas o spam.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Moderation.Flag
  alias Colloq.Forum.Post

  @doc """
  Crea un reporte (flag) sobre un post.

  Retorna {:ok, flag} o {:error, changeset}.
  """
  def flag_post(post_id, user_id, reason) do
    %Flag{}
    |> Flag.changeset(%{
      post_id: post_id,
      user_id: user_id,
      reason: reason
    })
    |> Repo.insert()
  end

  @doc """
  Resuelve un reporte existente.

  Marca el flag como resuelto, registra quién lo resolvió y la resolución.
  """
  def resolve_flag(flag_id, resolver_id, resolution) do
    flag = Repo.get!(Flag, flag_id)

    flag
    |> Flag.changeset(%{
      resolved: true,
      resolved_at: DateTime.utc_now(),
      resolved_by_id: resolver_id,
      resolution: resolution
    })
    |> Repo.update()
  end

  @doc """
  Lista los reportes pendientes de resolución.
  """
  def list_pending_flags do
    Flag
    |> where([f], f.resolved == false)
    |> preload([:post, :user])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Oculta un post (soft-delete, establece deleted_at).
  """
  def hide_post(%Post{} = post) do
    post
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Moderación automática de un post nuevo.

  Verifica contra una lista de palabras bloqueadas.
  Si el post contiene alguna, lo oculta automáticamente.
  También puede llamar a un detector externo de spam si está configurado.
  """
  def auto_moderate(%Post{} = post) do
    blocked_words = load_blocked_words()

    cond do
      contains_blocked_word?(post.body, blocked_words) ->
        hide_post(post)
        {:blocked, :profanity}

      should_check_spam?() ->
        spam_score = spam_detector(post)
        if spam_score > 0.8, do: hide_post(post)
        if spam_score > 0.8, do: {:blocked, :spam}, else: :ok

      true ->
        :ok
    end
  end

  defp load_blocked_words do
    case Colloq.SiteSettings.get("blocked_words") do
      nil -> []
      words when is_binary(words) -> String.split(words, ",", trim: true) |> Enum.map(&String.trim/1)
      words when is_list(words) -> words
    end
  end

  defp contains_blocked_word?(nil, _), do: false
  defp contains_blocked_word?(body, words) do
    body_downcase = String.downcase(body)
    Enum.any?(words, fn w -> String.contains?(body_downcase, String.downcase(w)) end)
  end

  defp should_check_spam? do
    Colloq.SiteSettings.get("spam_detection_enabled") == true
  end

  @doc """
  Heurísticas de detección de spam (sin Turnilio).
  
  Retorna un puntaje entre 0 y 1 donde 1 es spam seguro.
  """
  def spam_detector(%Post{} = post) do
    scores = [
      url_spam_score(post),
      duplicate_score(post),
      keyword_score(post)
    ]
    Enum.max(scores)
  end

  defp url_spam_score(%Post{body: body}) do
    url_count = Regex.scan(~r/https?:\/\//, body) |> length()
    cond do
      url_count > 5 -> 0.95
      url_count > 3 -> 0.6
      true -> 0.0
    end
  end

  defp duplicate_score(%Post{body: body, user_id: user_id}) do
    import Ecto.Query

    similar = from(p in Post,
      where: p.user_id == ^user_id,
      where: p.body == ^body,
      where: p.id != ^post.id,
      order_by: [desc: p.inserted_at],
      limit: 1
    ) |> Repo.one()

    if similar, do: 0.9, else: 0.0
  end

  defp keyword_score(%Post{body: body}) do
    blocked = Colloq.SiteSettings.get("blocked_keywords")
    if is_list(blocked) and length(blocked) > 0 do
      matches = Enum.count(blocked, fn kw -> String.contains?(String.downcase(body), String.downcase(kw)) end)
      min(matches * 0.25, 1.0)
    else
      0.0
    end
  end
end
