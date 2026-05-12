defmodule Cognition.CodingTool do
  @moduledoc false

  alias Cognition.CodingTool.{ClaudeCli, CodexAdapter}
  alias Cognition.Config

  @type session :: %{
          adapter: module(),
          adapter_session: term(),
          kind: String.t()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    adapter = adapter_module()

    with {:ok, adapter_session} <- adapter.start_session(workspace, opts) do
      {:ok, %{adapter: adapter, adapter_session: adapter_session, kind: Config.coding_tool_kind()}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{adapter: adapter, adapter_session: adapter_session}, prompt, issue, opts \\ []) do
    adapter.run_turn(adapter_session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{adapter: adapter, adapter_session: adapter_session}) do
    adapter.stop_session(adapter_session)
  end

  defp adapter_module do
    case Config.coding_tool_kind() do
      "claude" -> ClaudeCli
      _ -> CodexAdapter
    end
  end
end
