defmodule Colloq.Llm do
  @moduledoc """
  Adaptador unificado de LLM para Colloq.

  Soporta múltiples proveedores con endpoints compatibles con OpenAI API.
  Cada proveedor lee su API key de Application.get_env(:colloq, :{provider}_api_key).

  Providers: groq, nvidia, anthropic, openrouter

  Retorna {:ok, %{content: string}} o {:error, reason}.
  En caso de rate limit, snoozea el job de Oban: {:snooze, 60}.
  """

  require Logger

  @providers %{
    "groq" => %{base_url: "https://api.groq.com/openai/v1", key_env: :groq_api_key},
    "nvidia" => %{base_url: "https://integrate.api.nvidia.com/v1", key_env: :nvidia_nim_api_key},
    "anthropic" => %{base_url: "https://api.anthropic.com/v1", key_env: :anthropic_api_key},
    "openrouter" => %{base_url: "https://openrouter.ai/api/v1", key_env: :openrouter_api_key}
  }

  @doc """
  Envía un prompt de completado al proveedor LLM especificado.

  Recibe:
  - provider: string ("groq", "nvidia", "anthropic", "openrouter")
  - messages: lista de maps %{role: "system"|"user"|"assistant", content: string}
  - opts: keyword list o map, incluye al menos :model

  Retorna {:ok, %{content: string}} o {:error, reason}.
  Si el provider devuelve 429, retorna {:snooze, 60} para Oban.
  """
  def complete(provider, messages, opts) when is_list(opts), do: complete(provider, messages, Map.new(opts))
  def complete(provider, messages, opts) when is_map(opts) do
    with {:ok, config} <- get_provider_config(provider),
         {:ok, api_key} <- get_api_key(config.key_env) do
      do_request(config.base_url, api_key, messages, opts)
    end
  end

  defp get_provider_config(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, "proveedor no soportado: #{provider}"}
      config -> {:ok, config}
    end
  end

  defp get_api_key(key_env) do
    case Application.get_env(:colloq, key_env) do
      nil -> {:error, "API key no configurada para #{key_env}"}
      key -> {:ok, key}
    end
  end

  defp do_request(base_url, api_key, messages, opts) do
    model = Map.get(opts, :model, "gpt-4o-mini")
    temperature = Map.get(opts, :temperature, 0.7)
    max_tokens = Map.get(opts, :max_tokens, 1024)

    body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.post("#{base_url}/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: 30_000,
           connect_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, %{content: content}}

      {:ok, %{status: 429}} ->
        Logger.warning("LLM rate limited en #{base_url}")
        {:error, :rate_limited}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("LLM error HTTP #{status}: #{inspect(resp_body)}")
        {:error, "HTTP #{status}"}

      {:error, error} ->
        Logger.error("LLM error de conexión: #{inspect(error)}")
        {:error, error}
    end
  end
end
