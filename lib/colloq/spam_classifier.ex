defmodule Colloq.SpamClassifier do
  @moduledoc """
  Client for the local ONNX spam-classifier sidecar (see `spam_classifier/`).

  The sidecar runs a DistilBERT model fine-tuned for spam and exposes
  `POST /classify {text}` → `{label, score}`, where `score` is the softmax
  probability of the "spam" class (0.0–1.0).

  Everything here is **fail-open**: any misconfiguration, timeout, or bad
  response returns `{:error, _}` and callers treat that as "not spam" — a legit
  post must never be lost because the model is unreachable.

  The sidecar URL comes from the `spam_ml_url` site setting (runtime-tunable),
  falling back to the `:spam_ml_url` application env.
  """
  require Logger

  # Generous: the post is already stored and this runs in a background Oban job,
  # so latency doesn't matter — but we don't want a hung sidecar to block a worker.
  @timeout 800

  @doc """
  Classifies `text`. Returns `{:ok, %{label: label, score: float}}` or
  `{:error, reason}`. Never raises.
  """
  def classify(text) when is_binary(text) and text != "" do
    case base_url() do
      nil ->
        {:error, :not_configured}

      url ->
        request(url, text)
    end
  end

  def classify(_), do: {:error, :empty}

  defp request(url, text) do
    case Req.post("#{url}/classify",
           json: %{text: text},
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"score" => score} = body}} ->
        {:ok, %{label: Map.get(body, "label"), score: to_float(score)}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc "Whether a sidecar URL is configured at all."
  def configured?, do: not is_nil(base_url())

  defp base_url do
    case Colloq.SiteSettings.get("spam_ml_url") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> Application.get_env(:colloq, :spam_ml_url)
    end
  end

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
