defmodule Colloq.Bots do
  @moduledoc """
  Contexto de bots y personas bot.

  Gestiona las personas bot (usuarios que responden vía LLM cuando son mencionados)
  y los bots de sistema (scorebot, etc.).
  Incluye rate limiting por Cachex.
  """
  import Ecto.Query, warn: false
  alias Colloq.Repo
  alias Colloq.Bots.BotSystem

  @doc """
  Obtiene una persona bot por su slug.
  """
  def get_persona_by_slug(slug) do
    Repo.get_by(BotSystem, slug: slug, type: "persona")
  end

  @doc """
  Lista todas las personas bot activas.
  """
  def list_personas do
    BotSystem
    |> where(type: "persona")
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Lista todos los bots de sistema.
  """
  def list_system_bots do
    BotSystem
    |> where(type: "system")
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Verifica el rate limit para una persona bot por usuario.

  Usa Cachex para mantener un contador de invocaciones por persona+usuario.
  Retorna :ok si está dentro del límite, {:error, :rate_limited} si no.

  Límite por defecto: 5 invocaciones por minuto.
  """
  def check_rate_limit(persona_slug, user_id) do
    max_calls = Application.get_env(:colloq, :bot_rate_limit, 5)
    window_seconds = Application.get_env(:colloq, :bot_rate_window, 60)

    cache_key = "bot_rate:#{persona_slug}:#{user_id}"

    case Cachex.get(:forum_cache, cache_key) do
      {:ok, nil} ->
        Cachex.put(:forum_cache, cache_key, 1, ttl: :timer.seconds(window_seconds))
        :ok

      {:ok, count} when count < max_calls ->
        Cachex.incr(:forum_cache, cache_key)
        :ok

      {:ok, _count} ->
        {:error, :rate_limited}

      {:error, _} ->
        :ok
    end
  end
end
