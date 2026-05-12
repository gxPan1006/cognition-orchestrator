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
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Cognition.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: Cognition.PubSub},
      {Task.Supervisor, name: Cognition.TaskSupervisor},
      Cognition.WorkflowStore,
      Cognition.Orchestrator,
      Cognition.HttpServer,
      Cognition.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Cognition.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    Cognition.StatusDashboard.render_offline_status()
    :ok
  end
end
