defmodule Colloq.Workers.CaCommandWorker do
  @moduledoc """
  Answers `/ca <consulta>` commands, replying in-topic as CAbot.

  Copa Argentina only. Same shape as `SofascoreCommandWorker` and
  `F1CommandWorker`: keyword routing, one answered query per user per 10
  minutes, replies rendered as SVG system posts.

  Data comes from `Colloq.CopaArgentina` (FotMob's undocumented league feed),
  cached 30 minutes. Replies say whether the numbers were served from cache.
  """
  use Oban.Worker, queue: :scorebot, max_attempts: 3

  require Logger

  alias Colloq.{Accounts, CopaArgentina, Forum}
  alias Colloq.CopaArgentina.Svg

  @rate_ttl :timer.minutes(10)
  @throttle_notice_ttl :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}}) do
    post = Forum.get_post!(post_id)
    query = extract_query(post.body)

    cond do
      is_nil(query) ->
        :ok

      rate_limited?(post.user_id) ->
        maybe_throttle_notice(post)
        :ok

      true ->
        post_reply(post, build_reply(query))
        Cachex.put(:forum_cache, rate_key(post.user_id), System.system_time(:second), ttl: @rate_ttl)
        :ok
    end
  end

  @doc """
  Strips HTML and the `/ca` prefix. `""` when the command has no arguments,
  `nil` when the post isn't a `/ca` command.
  """
  def extract_query(body) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim()

    # One regex for both the test and the strip, with a word boundary: a bare
    # prefix check treated "/calendario" as "/ca" and returned the whole string
    # as the query.
    case Regex.run(~r/^\/ca\b(.*)/is, plain) do
      [_, rest] -> String.trim(rest)
      _ -> nil
    end
  end

  def extract_query(_), do: nil

  # --- Routing ---------------------------------------------------------------

  @doc false
  def build_reply(query) do
    norm = deaccent(String.downcase(query))

    # Spanish and English, same as FangioBot: the forum is Spanish but members
    # browsing with locale "en" reach for English words.
    cond do
      norm == "" ->
        upcoming_reply()

      String.contains?(norm, ["resultado", "jugado", "ultimo", "ultima", "result", "played"]) ->
        results_reply()

      String.contains?(norm, ["racing", "academia"]) ->
        team_reply("racing")

      String.contains?(norm, [
        "proximo",
        "proxima",
        "fixture",
        "cuando",
        "que viene",
        "upcoming",
        "next",
        "when"
      ]) ->
        upcoming_reply()

      String.contains?(norm, ["todo", "todos", "completo", "all", "fixtures"]) ->
        all_reply()

      true ->
        help_text()
    end
  end

  defp upcoming_reply do
    case CopaArgentina.upcoming(12) do
      {:ok, [], source} ->
        # Nothing left to play means the cup is over, not that the feed failed.
        case CopaArgentina.results(8) do
          {:ok, played, _} when played != [] ->
            {:svg, "Copa Argentina — últimos resultados", Svg.matches(played), source}

          _ ->
            "<p>No hay partidos programados de Copa Argentina.</p>"
        end

      {:ok, matches, source} ->
        {:svg, "Copa Argentina — próximos partidos", Svg.matches(matches), source}

      _ ->
        error_text()
    end
  end

  defp results_reply do
    case CopaArgentina.results(12) do
      {:ok, [], _} -> "<p>Todavía no se jugó ningún partido de Copa Argentina.</p>"
      {:ok, matches, source} -> {:svg, "Copa Argentina — resultados", Svg.matches(matches), source}
      _ -> error_text()
    end
  end

  defp all_reply do
    case CopaArgentina.matches() do
      {:ok, [], _} ->
        "<p>No pude obtener el fixture de Copa Argentina.</p>"

      {:ok, matches, source} ->
        # The full bracket is 56 matches — far too tall for one card. Show the
        # most recent results and everything still to come, which is what
        # "todo" actually means to a reader.
        {played, pending} = Enum.split_with(matches, &CopaArgentina.finished?/1)
        shown = Enum.take(played, -6) ++ Enum.take(pending, 10)
        {:svg, "Copa Argentina #{season_label()}", Svg.matches(shown), source}

      _ ->
        error_text()
    end
  end

  # Every Copa Argentina match involving one club.
  defp team_reply(needle) do
    case CopaArgentina.matches() do
      {:ok, matches, source} ->
        matches
        |> Enum.filter(fn m ->
          [get_in(m, ["home", "name"]), get_in(m, ["away", "name"])]
          |> Enum.any?(&String.contains?(String.downcase(to_string(&1)), needle))
        end)
        |> case do
          [] ->
            "<p>No encontré partidos de ese equipo en la Copa Argentina.</p>"

          found ->
            {:svg, "Copa Argentina — Racing", Svg.matches(found), source}
        end

      _ ->
        error_text()
    end
  end

  defp season_label do
    case CopaArgentina.details() do
      {:ok, %{season: season}, _} when not is_nil(season) -> season
      _ -> ""
    end
  end

  defp help_text do
    """
    <p>🏆 <strong>CAbot</strong> — Copa Argentina:</p>
    <ul>
      <li><code>/ca</code> — próximos partidos</li>
      <li><code>/ca resultados</code> — partidos ya jugados</li>
      <li><code>/ca racing</code> — el camino de Racing en la copa</li>
      <li><code>/ca todo</code> — resultados recientes y lo que viene</li>
    </ul>
    """
  end

  defp error_text,
    do: "<p>No pude obtener los datos de la Copa Argentina ahora mismo. Probá de nuevo en un rato.</p>"

  # --- Reply plumbing --------------------------------------------------------

  defp post_reply(post, {:svg, title, svg, source}) do
    post_reply_attrs(post, %{
      "body" => "🏆 #{esc(title)} · #{freshness(source)}",
      "is_system" => true,
      "system_type" => "standings",
      "event_data" => %{"svg" => svg, "title" => title, "cached" => source == :cached}
    })
  end

  defp post_reply(post, html) when is_binary(html) do
    post_reply_attrs(post, %{"body" => html})
  end

  defp freshness(:cached), do: "🗄️ cacheado"
  defp freshness(_), do: "🔄 recién actualizado"

  defp post_reply_attrs(post, attrs) do
    topic = Forum.get_topic!(post.topic_id)
    bot = get_or_create_bot()
    attrs = Map.put(attrs, "parent_id", post.id)

    case Forum.create_post(topic, bot, attrs) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Logger.warning("[CaCommand] could not reply in topic #{topic.id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[CaCommand] reply failed: #{inspect(error)}")
      :ok
  end

  defp get_or_create_bot do
    case Accounts.get_user_by_username("cabot") do
      nil ->
        {:ok, user} =
          Accounts.register_bot(%{
            email: "cabot@colloq.local",
            username: "cabot",
            display_name: "CAbot",
            password: "cabot-internal",
            password_confirmation: "cabot-internal"
          })

        user

      user ->
        user
    end
  end

  # --- Rate limiting ---------------------------------------------------------

  defp rate_key(user_id), do: "ca_cmd:#{user_id}"

  defp rate_limited?(user_id) do
    match?({:ok, ts} when is_integer(ts), Cachex.get(:forum_cache, rate_key(user_id)))
  end

  defp maybe_throttle_notice(post) do
    notice_key = "ca_throttled:#{post.user_id}"

    case Cachex.get(:forum_cache, notice_key) do
      {:ok, nil} ->
        post_reply(post, "<p>⏳ Esperá unos minutos entre consultas de <code>/ca</code>.</p>")
        Cachex.put(:forum_cache, notice_key, true, ttl: @throttle_notice_ttl)

      _ ->
        :ok
    end
  end

  defp deaccent(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
  end

  defp esc(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
