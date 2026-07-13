defmodule Colloq.Workers.WebhookDispatchWorker do
  @moduledoc """
  Webhook dispatch worker.

  Sends an HTTP POST to the webhook URL with the event payload.
  Retries up to 5 times with exponential backoff on failure.
  Updates last_delivery_at and last_status on the webhook record.
  """
  use Oban.Worker, queue: :events, max_attempts: 5

  alias Colloq.Repo
  alias Colloq.Webhooks.Webhook

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_id" => webhook_id, "event" => event, "payload" => payload}}) do
    case Repo.get(Webhook, webhook_id) do
      nil ->
        {:error, "webhook not found"}

      webhook ->
        {status, response} = dispatch(webhook.url, event, payload)

        webhook
        |> Webhook.delivery_changeset(%{
          last_delivery_at: DateTime.utc_now(),
          last_status: to_string(status),
          last_response: inspect(response)
        })
        |> Repo.update!()

        if status in [:error, :timeout] do
          {:error, response}
        else
          :ok
        end
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
        {:ok, nil}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, %{reason: :timeout}} ->
        {:timeout, :timeout}

      {:error, error} ->
        {:error, error}
    end
  end
end
