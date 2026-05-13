defmodule Cognition.ControlPlane.Prober do
  @moduledoc """
  Periodically pings each registered project runtime so the control plane can
  show live status + tokens without owning their orchestrators.
  """

  use GenServer
  require Logger

  alias Cognition.ControlPlane.Registry

  @default_interval_ms 5_000
  @default_request_timeout_ms 1_500

  @type opts :: [
          name: GenServer.name(),
          registry: GenServer.server(),
          interval_ms: pos_integer(),
          request_fun: (String.t() -> {:ok, map()} | {:error, term()})
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec probe_now(GenServer.server()) :: :ok
  def probe_now(server \\ __MODULE__) do
    send(server, :tick)
    :ok
  end

  @impl true
  def init(opts) do
    state = %{
      registry: Keyword.get(opts, :registry, Registry),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      request_fun: Keyword.get(opts, :request_fun, &probe_runtime/1)
    }

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state.registry
    |> Registry.list()
    |> Enum.each(fn entry -> probe_entry(entry, state) end)

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  defp probe_entry(entry, state) do
    case state.request_fun.(probe_url(entry)) do
      {:ok, body} ->
        Registry.update_runtime_state(state.registry, entry.id, %{
          status: :running,
          last_probe_at: DateTime.utc_now(),
          last_state: body,
          last_error: nil
        })

      {:error, :connection_refused} ->
        Registry.update_runtime_state(state.registry, entry.id, %{
          status: stopped_status_for(entry),
          last_probe_at: DateTime.utc_now(),
          last_state: nil,
          last_error: nil
        })

      {:error, reason} ->
        Registry.update_runtime_state(state.registry, entry.id, %{
          status: :error,
          last_probe_at: DateTime.utc_now(),
          last_error: format_reason(reason)
        })
    end
  end

  defp stopped_status_for(%{status: :starting}), do: :starting
  defp stopped_status_for(_entry), do: :stopped

  defp probe_url(%{port: port}), do: "http://127.0.0.1:#{port}/api/v1/state"

  defp probe_runtime(url) do
    case Req.get(url,
           connect_options: [timeout: @default_request_timeout_ms],
           receive_timeout: @default_request_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, %{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 5)

  defp schedule_tick(delay_ms) do
    Process.send_after(self(), :tick, max(delay_ms, 0))
  end
end
