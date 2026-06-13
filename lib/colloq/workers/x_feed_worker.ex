defmodule Colloq.Workers.XFeedWorker do
  @moduledoc """
  Worker de feed de X/Twitter vía Nitter RSS.

  Cron cada 30 minutos.
  Obtiene el feed RSS de Nitter para cuentas configuradas,
  parsea con SweetXml, filtra por palabras clave y
  publica tweets nuevos en el topic de feed como posts de sistema.

  Deduplicación vía Cachex con TTL de 7 días.
  """
  use Oban.Worker, queue: :events, max_attempts: 3

  alias Colloq.Repo
  alias Colloq.Forum
  alias Colloq.Forum.Topic
  alias Colloq.Forum.Post
  alias Colloq.Accounts
  alias Colloq.SiteSettings

  require Logger

  @nitter_base "https://nitter.net"

  @impl Oban.Worker
  def perform(_job) do
    accounts = load_accounts()
    keywords = load_keywords()
    feed_topic_id = SiteSettings.get("x_feed_topic_id")

    unless feed_topic_id do
      Logger.warning("[XFeed] x_feed_topic_id no configurado en SiteSettings")
      {:discard, "sin topic configurado"}
    else
      topic = Repo.get!(Topic, feed_topic_id)
      system_user = find_system_user()

      Enum.each(accounts, fn account ->
        fetch_and_publish(account, keywords, topic, system_user)
      end)

      :ok
    end
  end

  defp fetch_and_publish(account, keywords, topic, system_user) do
    url = "#{@nitter_base}/#{account}/rss"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        tweets = parse_tweets(body)
        filtered = filter_tweets(tweets, keywords)

        Enum.each(filtered, fn tweet ->
          unless duplicate?(tweet.link) do
            publish_tweet(tweet, account, topic, system_user)
            mark_published(tweet.link)
          end
        end)

      {:ok, %{status: status}} ->
        Logger.warning("[XFeed] Nitter devolvió #{status} para @#{account}")

      {:error, error} ->
        Logger.warning("[XFeed] Error obteniendo feed de @#{account}: #{inspect(error)}")
    end
  end

  defp parse_tweets(body) do
    import SweetXml

    doc = body |> String.valid?() && body |> SweetXml.parse()

    if doc do
      doc
      |> SweetXml.xpath(~x"//item",
        title: ~x"./title/text()"s,
        link: ~x"./link/text()"s,
        description: ~x"./description/text()"s,
        pub_date: ~x"./pubDate/text()"s
      )
    else
      []
    end
  end

  defp filter_tweets(tweets, []), do: tweets
  defp filter_tweets(tweets, keywords) do
    Enum.filter(tweets, fn tweet ->
      text = (tweet.title || "") <> " " <> String.replace(tweet.description || "", ~r/<[^>]+>/, "")
      text_downcase = String.downcase(text)

      Enum.any?(keywords, fn kw ->
        String.contains?(text_downcase, String.downcase(kw))
      end)
    end)
  end

  defp duplicate?(link) do
    cache_key = "xfeed:#{link}"
    {:ok, exists} = Cachex.exists?(:forum_cache, cache_key)
    exists
  end

  defp mark_published(link) do
    Cachex.put(:forum_cache, "xfeed:#{link}", true, ttl: :timer.hours(24 * 7))
  end

  defp publish_tweet(tweet, account, topic, system_user) do
    text = String.replace(tweet.description || "", ~r/<br\s*\/?>/, "\n")
    text = String.replace(text, ~r/<[^>]+>/, "")

    body = """
    <blockquote class="x-feed-quote">
      #{text}
      <footer>
        — <a href="#{tweet.link}" target="_blank" rel="noopener noreferrer">@#{account}</a>
      </footer>
    </blockquote>
    """

    post_attrs = %{
      "body" => body,
      "is_system" => true,
      "system_type" => "x_feed",
      "event_data" => %{
        account: account,
        url: tweet.link
      }
    }

    Forum.create_post(topic, system_user, post_attrs)
    Logger.info("[XFeed] Publicado tweet de @#{account}")
  end

  defp load_accounts do
    case SiteSettings.get("x_feed_accounts") do
      nil -> []
      accounts when is_binary(accounts) -> String.split(accounts, ",", trim: true) |> Enum.map(&String.trim/1)
      accounts when is_list(accounts) -> accounts
    end
  end

  defp load_keywords do
    case SiteSettings.get("x_feed_keywords") do
      nil -> []
      kw when is_binary(kw) -> String.split(kw, ",", trim: true) |> Enum.map(&String.trim/1)
      kw when is_list(kw) -> kw
    end
  end

  defp find_system_user do
    case Accounts.get_user_by_username("xfeed") do
      nil -> Accounts.get_user!(1)
      user -> user
    end
  end
end
