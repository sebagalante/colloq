defmodule Colloq.Workers.DolarCommandWorker do
  @moduledoc """
  Answers `/dolar [casa]` commands posted in a topic.

  Triggered on post creation when the body starts with `/dolar`. Fetches
  dolarapi.com (free, no key, one call returns every casa) and replies **in the
  same topic** as the `dolarbot` system user.

  The reply is plain HTML in the post body — which the `html5` body scrubber
  keeps for tables — so it is **frozen at post time**: a thread from three
  months ago keeps showing that day's rates, not today's.

  Two throttles, for different reasons:
    * the API response is cached 5 min, so a busy thread makes one HTTP call
      rather than one per post;
    * each user is rate limited to one query per 5 min, so `/dolar` can't be
      used to spam a topic.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Colloq.{Accounts, Forum}

  @api "https://dolarapi.com/v1/dolares"
  @cache_key "dolar:all"
  @cache_ttl :timer.minutes(5)

  # Short window on purpose: the API response is already cached, so a repeat
  # `/dolar` costs no HTTP call — this only stops someone carpet-bombing a
  # topic with bot replies.
  @rate_ttl :timer.minutes(1)
  @throttle_notice_ttl :timer.seconds(90)

  # dolarapi's `casa` values, in the order we display them, with their labels.
  @casas [
    {"oficial", "Oficial"},
    {"blue", "Blue"},
    {"bolsa", "MEP (Bolsa)"},
    {"contadoconliqui", "CCL"},
    {"mayorista", "Mayorista"},
    {"cripto", "Cripto"},
    {"tarjeta", "Tarjeta"}
  ]

  # What a user may type → the API's `casa` key.
  @aliases %{
    "oficial" => "oficial",
    "blue" => "blue",
    "mep" => "bolsa",
    "bolsa" => "bolsa",
    "ccl" => "contadoconliqui",
    "contadoconliqui" => "contadoconliqui",
    "mayorista" => "mayorista",
    "cripto" => "cripto",
    "tarjeta" => "tarjeta"
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}, attempt: attempt, max_attempts: max}) do
    post = Forum.get_post!(post_id)

    case extract_query(post.body) do
      nil ->
        :ok

      query ->
        if rate_limited?(post.user_id) do
          # Say so — silently doing nothing just looks like the command is broken.
          maybe_throttle_notice(post)
          :ok
        else
          case fetch() do
            {:ok, casas} ->
              post_reply(post, build_reply(casas, query))
              Cachex.put(:forum_cache, rate_key(post.user_id), true, ttl: @rate_ttl)
              :ok

            {:error, reason} ->
              Logger.warning("[DolarCommand] fetch failed (#{attempt}/#{max}): #{inspect(reason)}")

              # Network blips happen. Hand it back to Oban so it retries with
              # backoff, and only apologise once we've actually given up —
              # otherwise a hiccup leaves a permanent "no pude" in the thread.
              if attempt >= max do
                post_reply(post, "<p>No pude obtener las cotizaciones. Probá de nuevo en un rato.</p>")
                :ok
              else
                {:error, reason}
              end
          end
        end
    end
  end

  @doc """
  Strips HTML (posts are Tiptap HTML, so the body starts with `<p>`) and the
  `/dolar` prefix, returning the trimmed argument (`""` with no argument,
  `nil` when the post isn't a `/dolar` command).
  """
  def extract_query(body) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim()

    if plain |> String.downcase() |> String.starts_with?("/dolar") do
      plain |> String.replace(~r/^\/dolar\b/i, "") |> String.trim() |> String.downcase()
    else
      nil
    end
  end

  def extract_query(_), do: nil

  # --- Data ------------------------------------------------------------------

  defp fetch do
    case Cachex.get(:forum_cache, @cache_key) do
      {:ok, casas} when is_list(casas) -> {:ok, casas}
      _ -> refresh()
    end
  end

  defp refresh do
    # `retry: :transient` rides out a momentary blip before we bother Oban.
    case Req.get(@api, receive_timeout: 5_000, retry: :transient, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        Cachex.put(:forum_cache, @cache_key, body, ttl: @cache_ttl)
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Rendering -------------------------------------------------------------

  defp build_reply(casas, "") do
    rows = Enum.map(@casas, fn {key, label} -> row(casas, key, label) end) |> Enum.reject(&is_nil/1)

    """
    <table><thead><tr><th>Casa</th><th>Compra</th><th>Venta</th></tr></thead>
    <tbody>#{Enum.join(rows)}</tbody></table>
    <p>#{brecha_line(casas)}Fuente: dolarapi.com · #{updated_at(casas)}</p>
    """
  end

  defp build_reply(casas, query) do
    case Map.get(@aliases, query) do
      nil ->
        "<p>No conozco esa casa. Probá: <code>#{Enum.join(Map.keys(@aliases), ", ")}</code></p>"

      key ->
        label = @casas |> Enum.find(fn {k, _} -> k == key end) |> elem(1)

        case Enum.find(casas, &(&1["casa"] == key)) do
          nil ->
            "<p>No hay datos para #{label} ahora mismo.</p>"

          c ->
            "<p><strong>#{label}</strong>: compra #{money(c["compra"])} · venta <strong>#{money(c["venta"])}</strong>" <>
              " <em>(#{updated_at(casas)}, dolarapi.com)</em></p>"
        end
    end
  end

  defp row(casas, key, label) do
    case Enum.find(casas, &(&1["casa"] == key)) do
      nil -> nil
      c -> "<tr><td>#{label}</td><td>#{money(c["compra"])}</td><td><strong>#{money(c["venta"])}</strong></td></tr>"
    end
  end

  defp brecha_line(casas) do
    blue = Enum.find(casas, &(&1["casa"] == "blue"))
    oficial = Enum.find(casas, &(&1["casa"] == "oficial"))

    case brecha(blue, oficial) do
      nil -> ""
      pct -> "<strong>Brecha blue/oficial: #{fmt_pct(pct)}</strong> · "
    end
  end

  defp brecha(%{"venta" => b}, %{"venta" => o}) when is_number(b) and is_number(o) and o > 0,
    do: Float.round((b - o) / o * 100, 1)

  defp brecha(_, _), do: nil

  defp fmt_pct(pct) do
    sign = if pct >= 0, do: "+", else: ""
    sign <> (pct |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")) <> "%"
  end

  # Argentine formatting: "." for thousands, "," for decimals.
  defp money(n) when is_number(n) do
    int = n |> trunc() |> Integer.to_string()

    thousands =
      int
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
      |> String.reverse()

    "$" <> thousands
  end

  defp money(_), do: "—"

  defp updated_at(casas) do
    casas
    |> Enum.map(& &1["fechaActualizacion"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
    |> case do
      nil ->
        "actualizado recién"

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} ->
            local =
              case DateTime.shift_zone(dt, "America/Argentina/Buenos_Aires") do
                {:ok, l} -> l
                _ -> dt
              end

            "actualizado #{Calendar.strftime(local, "%d/%m %H:%M")}"

          _ ->
            "actualizado recién"
        end
    end
  end

  # --- Plumbing --------------------------------------------------------------

  defp rate_key(user_id), do: "dolar_cmd:#{user_id}"

  defp rate_limited?(user_id) do
    match?({:ok, true}, Cachex.get(:forum_cache, rate_key(user_id)))
  end

  # One notice per window, so a user spamming the command doesn't get the bot
  # spamming warnings back.
  defp maybe_throttle_notice(post) do
    notice_key = "dolar_throttled:#{post.user_id}"

    case Cachex.get(:forum_cache, notice_key) do
      {:ok, nil} ->
        post_reply(post, "<p>⏳ Esperá un minuto entre consultas de <code>/dolar</code>.</p>")
        Cachex.put(:forum_cache, notice_key, true, ttl: @throttle_notice_ttl)

      _ ->
        :ok
    end
  end

  defp post_reply(post, body) do
    topic = Forum.get_topic!(post.topic_id)
    bot = get_or_create_bot()

    # create_post/3 returns an error *tuple* (not a raise) when the topic is
    # closed/archived/announcement — the bot isn't staff, so it can't post
    # there. Log it instead of failing silently.
    case Forum.create_post(topic, bot, %{"body" => body, "parent_id" => post.id}) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Logger.warning(
          "[DolarCommand] could not reply in topic #{topic.id} (closed=#{topic.closed} " <>
            "archived=#{topic.archived} staff_only=#{topic.staff_only}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e -> Logger.error("[DolarCommand] reply failed: #{inspect(e)}")
  end

  defp get_or_create_bot do
    case Accounts.get_user_by_username("dolarbot") do
      nil ->
        {:ok, user} =
          Accounts.register_bot(%{
            email: "dolarbot@colloq.local",
            username: "dolarbot",
            display_name: "DolarBot",
            password: "dolarbot-internal",
            password_confirmation: "dolarbot-internal"
          })

        user

      user ->
        user
    end
  end
end
