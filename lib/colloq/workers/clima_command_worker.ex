defmodule Colloq.Workers.ClimaCommandWorker do
  @moduledoc """
  Answers `/clima <ciudad[, provincia]>` commands posted in a topic.

  Triggered on post creation when the body starts with `/clima`. Uses Open-Meteo
  (free, no API key): one geocoding call resolves the city → lat/lon, a second
  call fetches current conditions + a short forecast. Replies **in the same
  topic** as the `clima_bot` system user.

  The reply is an inline-styled HTML table (the `html5` body scrubber keeps
  `<table>` and `style`), so it's frozen at post time — an old thread keeps that
  day's forecast.

  `provincia` (after a comma) disambiguates among cities with the same name,
  matched against Open-Meteo's `admin1` field: `/clima Rosario, Santa Fe`.

  Throttles mirror the other command bots: the forecast is cached ~15 min and
  each user is rate limited to one query per minute so `/clima` can't spam a
  topic.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Colloq.{Accounts, Forum}

  @geo_api "https://geocoding-api.open-meteo.com/v1/search"
  @forecast_api "https://api.open-meteo.com/v1/forecast"

  @geo_ttl :timer.hours(24)
  @forecast_ttl :timer.minutes(15)
  @rate_ttl :timer.minutes(1)
  @throttle_notice_ttl :timer.seconds(90)

  # WMO weather codes → {emoji, Spanish label}.
  @wmo %{
    0 => {"☀️", "Despejado"},
    1 => {"🌤️", "Mayormente despejado"},
    2 => {"⛅", "Parcialmente nublado"},
    3 => {"☁️", "Nublado"},
    45 => {"🌫️", "Niebla"},
    48 => {"🌫️", "Niebla con escarcha"},
    51 => {"🌦️", "Llovizna leve"},
    53 => {"🌦️", "Llovizna"},
    55 => {"🌦️", "Llovizna intensa"},
    56 => {"🌧️", "Llovizna helada"},
    57 => {"🌧️", "Llovizna helada intensa"},
    61 => {"🌧️", "Lluvia leve"},
    63 => {"🌧️", "Lluvia"},
    65 => {"🌧️", "Lluvia intensa"},
    66 => {"🌧️", "Lluvia helada"},
    67 => {"🌧️", "Lluvia helada intensa"},
    71 => {"🌨️", "Nevada leve"},
    73 => {"🌨️", "Nevada"},
    75 => {"❄️", "Nevada intensa"},
    77 => {"🌨️", "Granos de nieve"},
    80 => {"🌦️", "Chaparrones leves"},
    81 => {"🌧️", "Chaparrones"},
    82 => {"⛈️", "Chaparrones fuertes"},
    85 => {"🌨️", "Chaparrones de nieve"},
    86 => {"❄️", "Chaparrones de nieve fuertes"},
    95 => {"⛈️", "Tormenta"},
    96 => {"⛈️", "Tormenta con granizo"},
    99 => {"⛈️", "Tormenta con granizo fuerte"}
  }

  @days_es ~w(dom lun mar mié jue vie sáb)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"post_id" => post_id}, attempt: attempt, max_attempts: max}) do
    post = Forum.get_post!(post_id)

    case extract_query(post.body) do
      nil ->
        :ok

      "" ->
        post_reply(post, help_text())
        :ok

      query ->
        cond do
          rate_limited?(post.user_id) ->
            maybe_throttle_notice(post)
            :ok

          true ->
            handle_query(post, query, attempt, max)
        end
    end
  end

  defp handle_query(post, query, attempt, max) do
    {city, province} = parse_place(query)

    with {:ok, place} <- geocode(city, province),
         {:ok, weather} <- forecast(place) do
      post_reply(post, build_reply(place, weather))
      Cachex.put(:forum_cache, rate_key(post.user_id), true, ttl: @rate_ttl)
      :ok
    else
      {:error, :not_found} ->
        post_reply(post, "<p>🔎 No encontré «#{esc(query)}». Probá con <code>ciudad, provincia</code>.</p>")
        :ok

      {:error, reason} ->
        Logger.warning("[ClimaCommand] failed (#{attempt}/#{max}): #{inspect(reason)}")

        if attempt >= max do
          post_reply(post, "<p>No pude obtener el clima. Probá de nuevo en un rato.</p>")
          :ok
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Strips the Tiptap HTML and the `/clima` prefix, returning the trimmed argument
  (`""` with no argument, `nil` when the post isn't a `/clima` command).
  """
  def extract_query(body) when is_binary(body) do
    plain = body |> HtmlSanitizeEx.strip_tags() |> String.trim()

    if plain |> String.downcase() |> String.starts_with?("/clima") do
      plain |> String.replace(~r/^\/clima\b/i, "") |> String.trim()
    else
      nil
    end
  end

  def extract_query(_), do: nil

  # "Rosario, Santa Fe" → {"Rosario", "Santa Fe"}; "Rosario" → {"Rosario", nil}.
  defp parse_place(query) do
    case String.split(query, ",", parts: 2) do
      [city, province] -> {String.trim(city), String.trim(province)}
      [city] -> {String.trim(city), nil}
    end
  end

  # --- Data ------------------------------------------------------------------

  defp geocode(city, province) do
    key = "clima:geo:" <> String.downcase("#{city}|#{province}")

    case Cachex.get(:forum_cache, key) do
      {:ok, %{} = place} ->
        {:ok, place}

      _ ->
        params = %{name: city, count: 8, language: "es", format: "json"}

        case Req.get(@geo_api, params: params, receive_timeout: 5_000, retry: :transient, max_retries: 2) do
          {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) and results != [] ->
            place = pick_place(results, province)
            Cachex.put(:forum_cache, key, place, ttl: @geo_ttl)
            {:ok, place}

          {:ok, %{status: 200}} ->
            {:error, :not_found}

          {:ok, %{status: status}} ->
            {:error, {:status, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Prefer a result whose admin1/country matches the given province; else the
  # first (Open-Meteo already sorts by relevance/population).
  defp pick_place(results, nil), do: normalize_place(hd(results))

  defp pick_place(results, province) do
    p = String.downcase(province)

    match =
      Enum.find(results, fn r ->
        String.contains?(String.downcase(to_string(r["admin1"] || "")), p) or
          String.contains?(String.downcase(to_string(r["country"] || "")), p)
      end)

    normalize_place(match || hd(results))
  end

  defp normalize_place(r) do
    %{
      name: r["name"],
      admin1: r["admin1"],
      country: r["country"],
      country_code: r["country_code"],
      lat: r["latitude"],
      lon: r["longitude"]
    }
  end

  defp forecast(%{lat: lat, lon: lon}) do
    key = "clima:fc:#{Float.round(lat * 1.0, 2)}:#{Float.round(lon * 1.0, 2)}"

    case Cachex.get(:forum_cache, key) do
      {:ok, %{} = w} ->
        {:ok, w}

      _ ->
        params = %{
          latitude: lat,
          longitude: lon,
          current: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m",
          daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
          timezone: "auto",
          forecast_days: 4
        }

        case Req.get(@forecast_api, params: params, receive_timeout: 5_000, retry: :transient, max_retries: 2) do
          {:ok, %{status: 200, body: body}} when is_map(body) ->
            Cachex.put(:forum_cache, key, body, ttl: @forecast_ttl)
            {:ok, body}

          {:ok, %{status: status}} ->
            {:error, {:status, status}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Rendering -------------------------------------------------------------

  # Mid-gray reads on both light and dark themes; a translucent border likewise.
  # Emphasis comes from font-weight + emoji, not hardcoded text colors, so the
  # reply stays legible whatever theme the reader is on (post bodies inherit it).
  @muted "color:#8a94a6"
  # Plain hex (the sanitizer strips rgba()); a neutral gray reads on both themes.
  @border "border-top:1px solid #888"

  defp build_reply(place, weather) do
    cur = weather["current"] || %{}
    {emoji, label} = wmo(cur["weather_code"])

    """
    <p style="font-size:15px;font-weight:700">📍 #{esc(place_line(place))}</p>
    <p style="margin:4px 0 6px">
      <span style="font-size:34px;vertical-align:middle">#{emoji}</span>
      <strong style="font-size:28px;vertical-align:middle"> #{temp(cur["temperature_2m"])}</strong>
      <span style="#{@muted};font-size:13px;vertical-align:middle"> #{esc(label)} · ST #{temp(cur["apparent_temperature"])}</span>
    </p>
    <p style="#{@muted};font-size:13px">💧 #{pct(cur["relative_humidity_2m"])} humedad · 💨 #{wind(cur["wind_speed_10m"])} · 🌧️ #{mm(cur["precipitation"])}</p>
    #{forecast_table(weather)}
    <p style="#{@muted};font-size:11px">Fuente: Open-Meteo</p>
    """
  end

  defp forecast_table(weather) do
    daily = weather["daily"] || %{}
    times = daily["time"] || []
    codes = daily["weather_code"] || []
    maxs = daily["temperature_2m_max"] || []
    mins = daily["temperature_2m_min"] || []
    probs = daily["precipitation_probability_max"] || []

    rows =
      times
      |> Enum.with_index()
      |> Enum.map_join("", fn {date, i} ->
        {e, lbl} = wmo(Enum.at(codes, i))

        """
        <tr style="#{@border}">
          <td style="padding:6px 8px;font-weight:600">#{day_label(date, i)}</td>
          <td style="padding:6px 8px">#{e} <span style="#{@muted};font-size:12px">#{esc(lbl)}</span></td>
          <td style="padding:6px 8px;text-align:right;white-space:nowrap">#{temp(Enum.at(mins, i))} / <strong>#{temp(Enum.at(maxs, i))}</strong></td>
          <td style="padding:6px 8px;text-align:right;#{@muted}">💧 #{pct(Enum.at(probs, i))}</td>
        </tr>
        """
      end)

    """
    <table style="width:100%;border-collapse:collapse;font-size:13px;max-width:460px">
      <thead><tr style="#{@muted};text-align:left;font-size:11px">
        <th style="padding:4px 8px">Día</th><th style="padding:4px 8px">Cielo</th>
        <th style="padding:4px 8px;text-align:right">Mín/Máx</th><th style="padding:4px 8px;text-align:right">Lluvia</th>
      </tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp place_line(%{name: name, admin1: admin1, country: country}) do
    [name, admin1, country] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")
  end

  defp day_label(date, 0), do: "Hoy"

  defp day_label(date, _) do
    case Date.from_iso8601(date) do
      {:ok, d} -> Enum.at(@days_es, Date.day_of_week(d, :sunday) - 1)
      _ -> date
    end
  end

  defp wmo(code) when is_integer(code), do: Map.get(@wmo, code, {"❓", "—"})
  defp wmo(_), do: {"❓", "—"}

  defp temp(n) when is_number(n), do: "#{round(n)}°"
  defp temp(_), do: "—"

  defp pct(n) when is_number(n), do: "#{round(n)}%"
  defp pct(_), do: "—"

  defp mm(n) when is_number(n), do: "#{:erlang.float_to_binary(n / 1.0, decimals: 1)} mm"
  defp mm(_), do: "0 mm"

  defp wind(n) when is_number(n), do: "#{round(n)} km/h"
  defp wind(_), do: "—"

  defp help_text do
    "<p>🌤️ <strong>ClimaBot</strong> — usá <code>/clima &lt;ciudad&gt;</code> o <code>/clima &lt;ciudad, provincia&gt;</code>. Ej: <code>/clima Rosario, Santa Fe</code></p>"
  end

  # --- Plumbing --------------------------------------------------------------

  defp rate_key(user_id), do: "clima_cmd:#{user_id}"

  defp rate_limited?(user_id) do
    match?({:ok, true}, Cachex.get(:forum_cache, rate_key(user_id)))
  end

  defp maybe_throttle_notice(post) do
    notice_key = "clima_throttled:#{post.user_id}"

    case Cachex.get(:forum_cache, notice_key) do
      {:ok, nil} ->
        post_reply(post, "<p>⏳ Esperá un minuto entre consultas de <code>/clima</code>.</p>")
        Cachex.put(:forum_cache, notice_key, true, ttl: @throttle_notice_ttl)

      _ ->
        :ok
    end
  end

  defp post_reply(post, body) do
    topic = Forum.get_topic!(post.topic_id)
    bot = get_or_create_bot()

    case Forum.create_post(topic, bot, %{"body" => body, "parent_id" => post.id}) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, reason} ->
        Logger.warning(
          "[ClimaCommand] could not reply in topic #{topic.id} (closed=#{topic.closed} " <>
            "archived=#{topic.archived} staff_only=#{topic.staff_only}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    e -> Logger.error("[ClimaCommand] reply failed: #{inspect(e)}")
  end

  defp get_or_create_bot do
    case Accounts.get_user_by_username("clima_bot") do
      nil ->
        {:ok, user} =
          Accounts.register_bot(%{
            email: "clima_bot@colloq.local",
            username: "clima_bot",
            display_name: "ClimaBot",
            password: "clima-bot-internal",
            password_confirmation: "clima-bot-internal"
          })

        user

      user ->
        user
    end
  end

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
