defmodule Colloq.Workers.LinkValidatorWorker do
  @moduledoc """
  Worker de validación de links en posts.

  Extrae todas las URLs del cuerpo de un post, verifica que cada una
  responda (HEAD request) y que el dominio no esté bloqueado.
  Si encuentra links rotos o bloqueados, reporta el post y notifica al autor.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum.Post
  alias Colloq.Moderation
  alias Colloq.Notifications
  alias Colloq.SiteSettings

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Repo.get!(Post, post_id) |> Repo.preload(:user)

    urls = extract_urls(post.body)

    if urls == [] do
      {:discard, "sin URLs"}
    else
      results = Enum.map(urls, &validate_url/1)
      dead_links = Enum.filter(results, &match?({:dead, _}, &1))
      blocked_links = Enum.filter(results, &match?({:blocked, _}, &1))

      cond do
        blocked_links != [] ->
          notify_author(post, :bloqueado, blocked_links)
          flag_post(post, "links_bloqueados", blocked_links)
          {:ok, "links bloqueados detectados"}

        dead_links != [] ->
          notify_author(post, :roto, dead_links)
          {:ok, "links rotos detectados"}

        true ->
          :ok
      end
    end
  end

  defp extract_urls(body) when is_nil(body), do: []
  defp extract_urls(body) do
    ~r/https?:\/\/[^\s<"]+/
    |> Regex.scan(body)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp validate_url(url) do
    uri = URI.parse(url)
    domain = uri.host

    if domain_blocked?(domain) do
      {:blocked, url}
    else
      case Req.head(url, follow_redirects: true, max_redirects: 5, receive_timeout: 5000) do
        {:ok, %{status: status}} when status in 200..399 -> {:ok, url}
        {:ok, %{status: status}} -> {:dead, url}
        {:error, _} -> {:dead, url}
      end
    end
  end

  defp domain_blocked?(nil), do: false
  defp domain_blocked?(domain) do
    blocked = load_blocked_domains()
    Enum.any?(blocked, fn d -> String.contains?(domain, d) end)
  end

  defp load_blocked_domains do
    case SiteSettings.get("blocked_domains") do
      nil -> []
      domains when is_binary(domains) -> String.split(domains, ",", trim: true) |> Enum.map(&String.trim/1)
      domains when is_list(domains) -> domains
    end
  end

  defp notify_author(post, reason, links) do
    link_list = Enum.map_join(links, "\n", fn {_, url} -> "• #{url}" end)

    messages = %{
      roto: "Algunos enlaces en tu post ya no responden",
      bloqueado: "Algunos enlaces en tu post apuntan a dominios bloqueados"
    }

    Notifications.create_notification(%{
      type: "system",
      title: messages[reason] || "Problema con enlaces en tu post",
      body: "Los siguientes enlaces fueron detectados:\n\n#{link_list}\n\nEditá tu post para corregirlos.",
      user_id: post.user_id,
      data: %{post_id: post.id, reason: reason, links: Enum.map(links, fn {_, u} -> u end)}
    })
  end

  defp flag_post(post, reason, links) do
    system_user_id = find_system_user_id()
    link_list = Enum.map_join(links, "\n", fn {_, u} -> u end)

    Moderation.flag_post(post.id, system_user_id, "spam")

    Logger.info("[LinkValidator] Post ##{post.id} reportado: #{reason} — #{link_list}")
  end

  defp find_system_user_id do
    case Colloq.Accounts.get_user_by_username("sistema") do
      nil -> 1
      user -> user.id
    end
  end
end
