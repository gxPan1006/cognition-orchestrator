defmodule Cognition.CodingTool.ClaudeCli do
  @moduledoc false

  @behaviour Cognition.CodingTool.Adapter

  require Logger

  alias Cognition.{Config, Linear.Issue, PathSafety, SSH}

  @type session :: %{
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, validated_workspace} <- validate_workspace_cwd(workspace, worker_host) do
      {:ok,
       %{
         thread_id: unique_id("claude-thread"),
         workspace: validated_workspace,
         worker_host: worker_host
       }}
    end
  end

  @impl true
  def run_turn(%{thread_id: thread_id, workspace: workspace, worker_host: worker_host}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = unique_id("claude-turn")
    session_id = "#{thread_id}-#{turn_id}"

    emit_message(on_message, :session_started, %{session_id: session_id, thread_id: thread_id, turn_id: turn_id})
    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id}")

    case run_claude_command(workspace, worker_host, prompt) do
      {:ok, output} ->
        payload = %{
          "method" => "turn/completed",
          "params" => %{
            "tool" => "claude",
            "output" => summarize_output(output)
          }
        }

        emit_message(on_message, :turn_completed, %{payload: payload, raw: output, session_id: session_id})
        Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        payload = %{
          "method" => "turn/failed",
          "params" => %{
            "tool" => "claude",
            "reason" => inspect(reason)
          }
        }

        emit_message(on_message, :turn_failed, %{payload: payload, reason: reason, session_id: session_id})
        Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp run_claude_command(workspace, worker_host, prompt) do
    command = Config.settings!().claude.command
    script = command_script(workspace, command, prompt)
    timeout_ms = Config.settings!().claude.turn_timeout_ms

    run_with_timeout(
      fn ->
        case worker_host do
          nil -> System.cmd("bash", ["-lc", script], stderr_to_stdout: true)
          host -> SSH.run(host, script, stderr_to_stdout: true)
        end
      end,
      timeout_ms
    )
  end

  defp run_with_timeout(fun, timeout_ms) when is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, {:claude_cli_exit, status, summarize_output(output)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :claude_cli_timeout}
    end
  end

  defp command_script(workspace, command, prompt) do
    delimiter = heredoc_delimiter(prompt)
    prompt_body = if String.ends_with?(prompt, "\n"), do: prompt, else: prompt <> "\n"

    "cd #{shell_escape(workspace)}\n" <>
      "cat <<'#{delimiter}' | #{command}\n" <>
      prompt_body <>
      delimiter
  end

  defp heredoc_delimiter(prompt) do
    base = "__COGNITION_CLAUDE_PROMPT__"

    if String.contains?(prompt, base) do
      base <> "_" <> unique_id("END")
    else
      base
    end
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp emit_message(on_message, event, payload) do
    payload =
      payload
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:coding_tool, "claude")

    on_message.(payload)
  end

  defp default_on_message(_message), do: :ok

  defp summarize_output(output) when is_binary(output) do
    if byte_size(output) > 2_000 do
      binary_part(output, 0, 2_000) <> "...<truncated>"
    else
      output
    end
  end

  defp summarize_output(output), do: inspect(output, printable_limit: 2_000)

  defp unique_id(prefix) do
    "#{prefix}-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue=unknown"
end
