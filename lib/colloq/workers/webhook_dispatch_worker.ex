defmodule Colloq.Workers.WebhookDispatchWorker do
  @moduledoc """
  Worker de despacho de webhooks.

  Realiza un HTTP POST a la URL del webhook con el payload del evento.
  Si falla, reintenta hasta 5 veces con backoff exponencial.
  Actualiza last_delivery_at y last_status en el registro del webhook.
  """
  use Oban.Worker, queue: :events, max_attempts: 5

  alias Colloq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => webhook_id, "event" => event, "payload" => payload}}) do
    webhook = Repo.get_by!(Colloq.Webhook, __get_webhook_schema(), id: webhook_id)

    {status, response} = dispatch(webhook.url, event, payload)

    Repo.update_all(
      Ecto.Query.from(w in "webhooks", where: w.id == ^webhook.id),
      set: [
        last_delivery_at: DateTime.utc_now(),
        last_status: status,
        last_response: inspect(response)
      ]
    )

    if status in ["error", "timeout"] do
      {:error, response}
    else
      :ok
    end
  end

  defp dispatch(url, event, payload) do
    body = Jason.encode!(%{event: event, payload: payload, timestamp: DateTime.utc_now()})

    case Req.post(url,
           headers: %{
             "content-type" => "application/json",
             "user-agent" => "Colloq-Webhook/1.0"
           },
           body: body,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        {"ok", nil}

      {:ok, %{status: status, body: resp_body}} ->
        {"error", %{status: status, body: resp_body}}

      {:error, %{reason: :timeout}} ->
        {"timeout", :timeout}

      {:error, error} ->
        {"error", error}
    end
  end

  defp __get_webhook_schema do
    # La tabla webhooks se lee directamente; no hay schema Ecto definido aún
    %{}
  end
end
