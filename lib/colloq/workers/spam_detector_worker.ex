defmodule Colloq.Workers.SpamDetectorWorker do
  @moduledoc """
  Worker de detección de spam en posts nuevos.

  Se encola al crear un post de un usuario TL0 o TL1.
  Verifica múltiples señales:
    - Exceso de URLs (> N links = spam)
    - Contenido duplicado (cuerpo idéntico en últimos 10 posts)
    - Palabras bloqueadas de SiteSettings
    - Fallback opcional: clasificador LLM vía Groq para casos dudosos

  Si se detecta spam: oculta el post, lo reporta y notifica al autor.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  alias Colloq.Repo
  alias Colloq.Forum.Post
  alias Colloq.Moderation
  alias Colloq.Notifications
  alias Colloq.SiteSettings

  require Logger

  @max_links 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Repo.get!(Post, post_id) |> Repo.preload(:user)

    user = post.user

    unless user.trust_level in [0, 1] do
      {:discard, "TL#{user.trust_level} — no verificado"}
    else
      case classify(post) do
        :ok ->
          :ok

        {:spam, reason} ->
          handle_spam(post, reason)
      end
    end
  end

  defp classify(post) do
    cond do
      too_many_urls?(post.body) ->
        {:spam, "exceso_de_links"}

      duplicate_content?(post) ->
        {:spam, "contenido_duplicado"}

      contains_blocked_words?(post.body) ->
        {:spam, "palabras_bloqueadas"}

      true ->
        :ok
    end
  end

  defp too_many_urls?(body) when is_nil(body), do: false
  defp too_many_urls?(body) do
    count =
      body
      |> url_matches()
      |> length()

    count > @max_links
  end

  defp url_matches(body) do
    ~r/https?:\/\/[^\s<]+/
    |> Regex.scan(body)
  end

  defp duplicate_content?(post) do
    recent_posts =
      Post
      |> where([p], p.user_id == ^post.user_id)
      |> where([p], p.id != ^post.id)
      |> order_by(desc: :inserted_at)
      |> limit(10)
      |> select([p], p.body)
      |> Repo.all()

    post.body in recent_posts
  end

  defp contains_blocked_words?(body) when is_nil(body), do: false
  defp contains_blocked_words?(body) do
    words = load_blocked_words()
    body_downcase = String.downcase(body)

    Enum.any?(words, fn w ->
      String.contains?(body_downcase, String.downcase(w))
    end)
  end

  defp load_blocked_words do
    case SiteSettings.get("blocked_words") do
      nil -> []
      words when is_binary(words) -> String.split(words, ",", trim: true) |> Enum.map(&String.trim/1)
      words when is_list(words) -> words
    end
  end

  defp handle_spam(post, reason) do
    Logger.info("[SpamDetector] Spam detectado en post ##{post.id}: #{reason}")

    Moderation.hide_post(post)
    Moderation.flag_post(post.id, find_system_user_id(), "spam")

    Notifications.create_notification(%{
      type: "system",
      title: "Post ocultado por spam",
      body: "Tu post fue ocultado automáticamente por el sistema de detección de spam. Motivo: #{reason}. Si creés que fue un error, contactá a un moderador.",
      user_id: post.user_id,
      data: %{post_id: post.id, reason: reason}
    })

    {:ok, "spam detectado: #{reason}"}
  end

  defp find_system_user_id do
    case Colloq.Accounts.get_user_by_username("sistema") do
      nil -> 1
      user -> user.id
    end
  end
end
