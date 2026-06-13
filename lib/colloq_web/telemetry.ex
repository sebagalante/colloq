defmodule ColloqWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def metrics do
    [
      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.memory.processes", unit: {:byte, :kilobyte}),
      last_value("vm.memory.binary", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Phoenix Metrics
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration", tags: [:route], unit: {:native, :millisecond}),
      summary("phoenix.live_view.mount.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_event.stop.duration", tags: [:event], unit: {:native, :millisecond}),

      # Database Metrics
      summary("colloq.repo.query.total_time", unit: {:native, :millisecond}),
      summary("colloq.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("colloq.repo.query.query_time", unit: {:native, :millisecond}),
      summary("colloq.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("colloq.repo.query.idle_time", unit: {:native, :millisecond}),

      # Oban Metrics
      counter("oban.job.start", tags: [:worker]),
      summary("oban.job.stop.duration", tags: [:worker], unit: {:native, :millisecond}),
      counter("oban.job.exception", tags: [:worker]),

      # Cachex Metrics
      last_value("cachex.forum_cache.size"),
      counter("cachex.forum_cache.hit"),
      counter("cachex.forum_cache.miss"),

      # Custom Application Metrics
      counter("colloq.post.created"),
      counter("colloq.topic.created"),
      counter("colloq.reaction.toggled", tags: [:emoji]),
      counter("colloq.match.event", tags: [:type]),
      last_value("colloq.connected_users")
    ]
  end

  def init(_arg) do
    children = [
      # Telemetry poller periodically collects VM metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def periodic_measurements do
    [
      {ColloqWeb.Telemetry.VM, :memory, []},
      {ColloqWeb.Telemetry.VM, :run_queue_lengths, []}
    ]
  end

  defmodule VM do
    @moduledoc "Periodic VM metric collection"

    def memory do
      memory = :erlang.memory()
      :telemetry.execute([:vm, :memory], %{
        total: memory[:total],
        processes: memory[:processes],
        binary: memory[:binary]
      })
    end

    def run_queue_lengths do
      :telemetry.execute([:vm, :total_run_queue_lengths], %{
        total: :erlang.statistics(:total_run_queue_lengths_all),
        cpu: :erlang.statistics(:total_run_queue_lengths_cpu),
        io: :erlang.statistics(:total_run_queue_lengths_io)
      })
    end
  end
end
