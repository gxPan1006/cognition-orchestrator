defmodule Cognition.CodingTool.CodexAdapter do
  @moduledoc false

  @behaviour Cognition.CodingTool.Adapter

  alias Cognition.Codex.AppServer

  @impl true
  def start_session(workspace, opts \\ []) do
    AppServer.start_session(workspace, opts)
  end

  @impl true
  def run_turn(session, prompt, issue, opts \\ []) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
