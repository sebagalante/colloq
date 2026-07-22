defmodule Colloq.Workers.PushNotificationWorker do
  @moduledoc """
  Web push notification delivery worker (PWA).

  Triggered by ScoreBotWorker on goals, cards, or full-time.
  Loads all push subscriptions from users following the involved team
  and sends a web push notification to each.

  Notifications use the "match-event" tag so they replace
  each other on the device.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Colloq.PushSubscriptions

  require Logger

  # Match events are only interesting live, so let them expire quickly.
  @ttl_seconds 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_type" => "goal"} = args}) do
    payload = build_goal_payload(args)
    send_to_fans(payload, args["team_id"])
  end

  def perform(%Oban.Job{args: %{"event_type" => "card"} = args}) do
    payload = build_card_payload(args)
    send_to_fans(payload, args["team_id"])
  end

  def perform(%Oban.Job{args: %{"event_type" => "ft"} = args}) do
    payload = build_ft_payload(args)
    send_to_fans(payload, args["team_id"])
  end

  defp build_goal_payload(args) do
    player = args["player"] || "Racing"
    minute = args["minute"] || ""
    score = args["score"] || ""
    opponent = args["opponent"] || ""

    title = "⚽ GOOOL DE LA ACADEMIA!"
    body = "#{player} #{minute}' — #{score} vs #{opponent}"

    build_payload(title, body, args)
  end

  defp build_card_payload(args) do
    player = args["player"] || ""
    minute = args["minute"] || ""
    card_type = args["card_type"] || "amarilla"
    card_emoji = if card_type == "roja", do: "🟥", else: "🟨"
    card_name = if card_type == "roja", do: "Roja", else: "Amarilla"

    title = "🟥/🟨 Tarjeta — #{player} #{minute}'"
    body = "#{card_emoji} Tarjeta #{card_name} — #{player} #{minute}'"

    build_payload(title, body, args)
  end

  defp build_ft_payload(args) do
    home = args["home_score"] || 0
    away = args["away_score"] || 0
    opponent = args["opponent"] || ""

    title = "⚡ Final: Racing #{home}-#{away} #{opponent}"
    body = "Partido finalizado. Racing #{home} - #{away} #{opponent}"

    build_payload(title, body, args)
  end

  defp build_payload(title, body, args) do
    %{
      title: title,
      body: body,
      icon: args["icon"] || "/images/racing-icon-192.png",
      badge: args["badge"] || "/images/racing-badge-72.png",
      url: build_url(args),
      tag: "match-event",
      requireInteraction: false,
      silent: false
    }
  end

  defp build_url(args) do
    if args["topic_id"] do
      "/t/#{args["topic_id"]}"
    else
      "/"
    end
  end

  defp send_to_fans(payload, team_id) do
    subscriptions = PushSubscriptions.for_team(team_id)

    Enum.each(subscriptions, fn sub ->
      send_push(sub, payload)
    end)

    Logger.info("[PushNotification] Enviadas a #{length(subscriptions)} suscriptores del equipo #{team_id}")
    :ok
  end

  # Encryption, VAPID headers and the POST are all handled by send_web_push/4.
  # This used to hand-roll them via WebPushEncryption.encrypt/5, which does not
  # exist (the library exports encrypt/2 and /3), so every send raised.
  defp send_push(subscription, payload) do
    if vapid_configured?() do
      subscription
      |> to_web_push_subscription()
      |> then(&WebPushEncryption.send_web_push(Jason.encode!(payload), &1, nil, @ttl_seconds))
      |> handle_push_response(subscription)
    else
      Logger.warning("[PushNotification] VAPID keys no configuradas")
      {:discard, "sin VAPID keys"}
    end
  end

  defp vapid_configured? do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      details when is_list(details) ->
        is_binary(details[:public_key]) and is_binary(details[:private_key])

      _ ->
        false
    end
  end

  defp to_web_push_subscription(subscription) do
    %{
      endpoint: subscription.endpoint,
      keys: %{p256dh: subscription.p256dh, auth: subscription.auth}
    }
  end

  defp handle_push_response(response, subscription) do
    case response do
      {:ok, %{status_code: status}} when status in 200..299 ->
        :ok

      # 404/410 mean the browser dropped the subscription — stop retrying it.
      {:ok, %{status_code: status}} when status in [404, 410] ->
        Logger.info("[PushNotification] Suscripción expirada: #{subscription.endpoint}")
        PushSubscriptions.unsubscribe(subscription.user_id, subscription.endpoint)
        :ok

      {:ok, %{status_code: status}} ->
        Logger.warning("[PushNotification] Status #{status} para #{subscription.endpoint}")
        :ok

      {:error, reason} ->
        Logger.warning("[PushNotification] Error enviando push: #{inspect(reason)}")
        :ok
    end
  end
end
