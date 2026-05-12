defmodule Cognition.CodingTool.Adapter do
  @moduledoc false

  @type session :: term()
  @type worker_host :: String.t() | nil

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok
end
