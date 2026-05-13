defmodule Cognition do
  @moduledoc """
  Entry point for the Cognition orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Cognition.Orchestrator.start_link(opts)
  end
end

defmodule Cognition.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.

  Two modes are supported:

  * `:project` (default) — full Symphony-style orchestrator for a single
    project: WorkflowStore + Orchestrator + StatusDashboard + HTTP API.
  * `:control_plane` — lightweight registry of project runtimes. No
    orchestrator, no workflow loader; only the HTTP endpoint, the
    `ControlPlane.Registry`, and the `ControlPlane.Prober` that pings every
    registered runtime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Cognition.LogFile.configure()

    children = children_for(runtime_mode())

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Cognition.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    case runtime_mode() do
      :control_plane -> :ok
      _ -> Cognition.StatusDashboard.render_offline_status()
    end

    :ok
  end

  @spec runtime_mode() :: :project | :control_plane
  def runtime_mode do
    case Application.get_env(:cognition, :runtime_mode) do
      :control_plane -> :control_plane
      _ -> :project
    end
  end

  defp children_for(:control_plane) do
    [
      {Phoenix.PubSub, name: Cognition.PubSub},
      {Task.Supervisor, name: Cognition.TaskSupervisor},
      Cognition.ControlPlane.Registry,
      Cognition.ControlPlane.Prober,
      Cognition.HttpServer
    ]
  end

  defp children_for(_project) do
    [
      {Phoenix.PubSub, name: Cognition.PubSub},
      {Task.Supervisor, name: Cognition.TaskSupervisor},
      Cognition.WorkflowStore,
      Cognition.Orchestrator,
      Cognition.HttpServer,
      Cognition.StatusDashboard
    ]
  end
end
