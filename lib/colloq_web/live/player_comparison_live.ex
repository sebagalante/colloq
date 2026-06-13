defmodule ColloqWeb.PlayerComparisonLive do
  use ColloqWeb, :live_view

  alias Phoenix.PubSub

  @seasons [
    {"23/24", "2023-2024"},
    {"24/25", "2024-2025"},
    {"25/26", "2025-2026"}
  ]

  @comparison_stats [
    %{section: "presencia", label: "Presencia", stats: [
      %{key: "partidos", label: "Partidos Jugados", emoji: "👟"},
      %{key: "minutos", label: "Minutos", emoji: "⏱️"},
      %{key: "titularidades", label: "Titularidades", emoji: "▶️"}
    ]},
    %{section: "ataque", label: "Ataque", stats: [
      %{key: "goles", label: "Goles", emoji: "⚽"},
      %{key: "asistencias", label: "Asistencias", emoji: "🎯"},
      %{key: "remates", label: "Remates al Arco", emoji: "🥅"},
      %{key: "xg", label: "xG", emoji: "📊"},
      %{key: "pases_clave", label: "Pases Clave", emoji: "🔑"}
    ]},
    %{section: "defensa", label: "Defensa", stats: [
      %{key: "intercepciones", label: "Intercepciones", emoji: "🛡️"},
      %{key: "entradas", label: "Entradas", emoji: "💪"},
      %{key: "despejes", label: "Despejes", emoji: "🧹"},
      %{key: "duelos_ganados", label: "Duelos Ganados", emoji: "🤼"}
    ]},
    %{section: "disciplina", label: "Disciplina", stats: [
      %{key: "amarillas", label: "Amarillas", emoji: "🟨"},
      %{key: "rojas", label: "Rojas", emoji: "🟥"},
      %{key: "faltas_cometidas", label: "Faltas Cometidas", emoji: "⚠️"},
      %{key: "faltas_recibidas", label: "Faltas Recibidas", emoji: "🤕"}
    ]}
  ]

  @impl true
  def mount(params, _session, socket) do
    player_a_id = parse_player_id(params, "a")
    player_b_id = parse_player_id(params, "b")
    season = Map.get(params, "season", "2024-2025")

    socket =
      socket
      |> assign(:page_title, "Comparar Jugadores")
      |> assign(:seasons, @seasons)
      |> assign(:comparison_stats, @comparison_stats)
      |> assign(:player_a, nil)
      |> assign(:player_b, nil)
      |> assign(:player_a_stats, nil)
      |> assign(:player_b_stats, nil)
      |> assign(:season, season)
      |> assign(:comparing, false)
      |> assign(:search_results, [])

    if connected?(socket) do
      PubSub.subscribe(Colloq.PubSub, "player_comparison_ready")
    end

    socket =
      if player_a_id && player_b_id do
        socket
        |> assign(:comparing, true)
        |> trigger_comparison(player_a_id, player_b_id, season)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("compare", %{"player_a" => a, "player_b" => b}, socket) do
    season = socket.assigns.season
    player_a_id = String.to_integer(a)
    player_b_id = String.to_integer(b)

    socket =
      socket
      |> assign(:comparing, true)
      |> assign(:player_a, nil)
      |> assign(:player_b, nil)
      |> assign(:player_a_stats, nil)
      |> assign(:player_b_stats, nil)
      |> trigger_comparison(player_a_id, player_b_id, season)
      |> push_patch(to: ~p"/comparar?a=#{player_a_id}&b=#{player_b_id}&season=#{season}")

    {:noreply, socket}
  end

  def handle_event("select-season", %{"season" => season}, socket) do
    player_a = socket.assigns.player_a
    player_b = socket.assigns.player_b

    socket =
      socket
      |> assign(:season, season)

    socket =
      if player_a && player_b do
        trigger_comparison(socket, player_a.id, player_b.id, season)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("search-players", %{"query" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        search_players(query)
      else
        []
      end

    {:noreply, assign(socket, :search_results, results)}
  end

  @impl true
  def handle_info({:comparison_ready, data}, socket) do
    player_a_id = socket.assigns[:player_a] && socket.assigns.player_a[:id]
    player_b_id = socket.assigns[:player_b] && socket.assigns.player_b[:id]

    cond do
      data.player_a.id == player_a_id ->
        {:noreply, assign(socket, :player_a_stats, data.player_a.stats)}

      data.player_b.id == player_b_id ->
        {:noreply, assign(socket, :player_b_stats, data.player_b.stats)}

      true ->
        {:noreply, socket}
    end
  end

  defp parse_player_id(params, key) do
    case Map.get(params, key) do
      nil -> nil
      id when is_binary(id) -> String.to_integer(id)
      id when is_integer(id) -> id
    end
  end

  defp trigger_comparison(socket, player_a_id, player_b_id, season) do
    case Cachex.get(:forum_cache, "player:#{player_a_id}:#{season}") do
      {:ok, nil} ->
        enqueue_comparison(player_a_id, player_b_id, season)
        load_from_cache_or_empty(socket, player_a_id, player_b_id, season)

      {:ok, cached_a} ->
        case Cachex.get(:forum_cache, "player:#{player_b_id}:#{season}") do
          {:ok, nil} ->
            enqueue_comparison(player_a_id, player_b_id, season)
            socket |> assign(:player_a, %{id: player_a_id}) |> assign(:player_a_stats, cached_a)

          {:ok, cached_b} ->
            socket
            |> assign(:player_a, %{id: player_a_id})
            |> assign(:player_b, %{id: player_b_id})
            |> assign(:player_a_stats, cached_a)
            |> assign(:player_b_stats, cached_b)
        end

      _error ->
        enqueue_comparison(player_a_id, player_b_id, season)
        socket
    end
  end

  defp enqueue_comparison(player_a_id, player_b_id, season) do
    %{player_a_id: player_a_id, player_b_id: player_b_id, season: season}
    |> Colloq.Workers.PlayerStatsWorker.new()
    |> Oban.insert()
  end

  defp load_from_cache_or_empty(socket, player_a_id, player_b_id, season) do
    {:ok, a} = Cachex.get(:forum_cache, "player:#{player_a_id}:#{season}")
    {:ok, b} = Cachex.get(:forum_cache, "player:#{player_b_id}:#{season}")

    socket
    |> assign(:player_a, %{id: player_a_id})
    |> assign(:player_b, %{id: player_b_id})
    |> assign(:player_a_stats, a || %{})
    |> assign(:player_b_stats, b || %{})
  end

  defp search_players(query) do
    import Ecto.Query

    like = "%#{query}%"

    Colloq.Accounts.User
    |> where([u], ilike(u.display_name, ^like) or ilike(u.username, ^like))
    |> limit(10)
    |> select([u], %{id: u.id, display_name: u.display_name, username: u.username})
    |> Colloq.Repo.all()
  end

  def bar_width(val, other) do
    max_val = max(val, other)
    if max_val == 0, do: 0, else: round(val / max_val * 100)
  end

  def win_count(a_stats, b_stats) when is_map(a_stats) and is_map(b_stats) do
    @comparison_stats
    |> Enum.flat_map(& &1.stats)
    |> Enum.count(fn stat ->
      Map.get(a_stats, stat.key, 0) > Map.get(b_stats, stat.key, 0)
    end)
  end

  def win_count(_, _), do: 0

  def tie_count(a_stats, b_stats) when is_map(a_stats) and is_map(b_stats) do
    @comparison_stats
    |> Enum.flat_map(& &1.stats)
    |> Enum.count(fn stat ->
      Map.get(a_stats, stat.key, 0) == Map.get(b_stats, stat.key, 0)
    end)
  end

  def tie_count(_, _), do: 0
end
