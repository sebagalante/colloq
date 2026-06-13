defmodule Colloq.Workers.PushNotificationWorker do
  @moduledoc """
  Worker de envío de notificaciones push web (PWA).

  Llamado por ScoreBotWorker cuando ocurre un gol, tarjeta o
  final de partido. Carga todas las suscripciones push de usuarios
  que siguen a Racing Club (team_id 174) y envía una notificación
  web push a cada una.

  Las notificaciones usan el tag "match-event" para que se reemplacen
  entre sí en el dispositivo.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  alias Colloq.PushSubscriptions

  require Logger

  @racing_id 174
  @vapid_subject "mailto:no-reply@colloq.ar"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_type" => "goal"} = args}) do
    payload = build_goal_payload(args)
    send_to_racing_fans(payload)
  end

  def perform(%Oban.Job{args: %{"event_type" => "card"} = args}) do
    payload = build_card_payload(args)
    send_to_racing_fans(payload)
  end

  def perform(%Oban.Job{args: %{"event_type" => "ft"} = args}) do
    payload = build_ft_payload(args)
    send_to_racing_fans(payload)
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

  defp send_to_racing_fans(payload) do
    subscriptions = PushSubscriptions.for_team(@racing_id)

    Enum.each(subscriptions, fn sub ->
      send_push(sub, payload)
    end)

    Logger.info("[PushNotification] Enviadas a #{length(subscriptions)} suscriptores")
    :ok
  end

  defp send_push(subscription, payload) do
    vapid_public = Application.get_env(:colloq, :vapid_public_key)
    vapid_private = Application.get_env(:colloq, :vapid_private_key)

    unless vapid_public && vapid_private do
      Logger.warning("[PushNotification] VAPID keys no configuradas")
      {:discard, "sin VAPID keys"} and throw(:skip)
    end

    message = WebPushEncryption.encrypt(
      Jason.encode!(payload),
      %{
        endpoint: subscription.endpoint,
        keys: %{
          p256dh: subscription.p256dh,
          auth: subscription.auth
        }
      },
      vapid_private,
      vapid_public,
      @vapid_subject
    )

    case message do
      {:ok, %{body: body, headers: headers}} ->
        send_to_endpoint(subscription.endpoint, body, headers)

      {:error, reason} ->
        Logger.error("[PushNotification] Error cifrando mensaje: #{inspect(reason)}")
    end
  catch
    :skip -> {:discard, "sin VAPID keys"}
  end

  defp send_to_endpoint(endpoint, body, headers) do
    case Req.post(endpoint,
           headers: Map.merge(headers, %{
             "content-type" => "application/octet-stream",
             "content-encoding" => "aes128gcm",
             "ttl" => "60"
           }),
           body: body,
           receive_timeout: 5_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 410}} ->
        Logger.info("[PushNotification] Suscripción expirada: #{endpoint}")

      {:ok, %{status: status}} ->
        Logger.warning("[PushNotification] Status #{status} para #{endpoint}")

      {:error, reason} ->
        Logger.warning("[PushNotification] Error enviando push: #{inspect(reason)}")
    end
  end
end
