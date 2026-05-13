defmodule Cognition.CodingTool.ClaudeCli do
  @moduledoc false

  @behaviour Cognition.CodingTool.Adapter

  require Logger

  alias Cognition.{Config, Linear.Issue, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @assistant_summary_limit 400
  @recent_lines_kept 20
  @error_output_byte_limit 4_000

  @type session :: %{
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          claude_session_store: pid()
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, validated_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, claude_session_store} <- Agent.start_link(fn -> nil end) do
      {:ok,
       %{
         thread_id: unique_id("claude-thread"),
         workspace: validated_workspace,
         worker_host: worker_host,
         claude_session_store: claude_session_store
       }}
    end
  end

  @impl true
  def run_turn(%{thread_id: thread_id, workspace: workspace, worker_host: worker_host, claude_session_store: store}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = unique_id("claude-turn")
    session_id = "#{thread_id}-#{turn_id}"
    resume_id = current_claude_session_id(store)

    emit_message(on_message, :session_started, %{
      session_id: session_id,
      thread_id: thread_id,
      turn_id: turn_id,
      resumed_claude_session_id: resume_id
    })

    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{session_id} resume=#{resume_id || "fresh"}")

    case run_claude_command_streaming(workspace, worker_host, prompt, on_message, session_id, resume_id) do
      {:ok, summary} ->
        # Pin the claude_session_id seen during this turn so the next turn in
        # the same dispatch resumes from it.
        maybe_remember_claude_session(store, summary.claude_session_id)

        output_text = summary.last_text |> summarize_text(@error_output_byte_limit)

        emit_message(on_message, :turn_completed, %{
          payload: %{
            "method" => "turn/completed",
            "params" => %{"tool" => "claude", "output" => output_text}
          },
          usage: summary.cumulative_usage,
          session_id: session_id,
          claude_session_id: summary.claude_session_id
        })

        Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id} claude_session_id=#{summary.claude_session_id || "n/a"}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id,
           claude_session_id: summary.claude_session_id
         }}

      {:error, reason} ->
        emit_message(on_message, :turn_failed, %{
          payload: %{
            "method" => "turn/failed",
            "params" => %{"tool" => "claude", "reason" => inspect(reason)}
          },
          session_id: session_id,
          reason: reason
        })

        Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{claude_session_store: store}) when is_pid(store) do
    if Process.alive?(store), do: Agent.stop(store, :normal, 1_000)
    :ok
  rescue
    _ -> :ok
  end

  def stop_session(_session), do: :ok

  defp current_claude_session_id(store) when is_pid(store) do
    if Process.alive?(store), do: Agent.get(store, & &1), else: nil
  rescue
    _ -> nil
  end

  defp current_claude_session_id(_store), do: nil

  defp maybe_remember_claude_session(store, id)
       when is_pid(store) and is_binary(id) and id != "" do
    if Process.alive?(store) do
      Agent.update(store, fn _ -> id end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_remember_claude_session(_store, _id), do: :ok

  defp run_claude_command_streaming(workspace, worker_host, prompt, on_message, session_id, resume_id) do
    command = Config.settings!().claude.command |> append_resume_flag(resume_id)
    script = command_script(workspace, command, prompt)
    timeout_ms = Config.settings!().claude.turn_timeout_ms

    case start_port(workspace, worker_host, script) do
      {:ok, port} ->
        try do
          stream_loop(
            port,
            on_message,
            session_id,
            timeout_ms,
            "",
            initial_summary(),
            []
          )
        after
          stop_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_port(_workspace, nil, script) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(script)],
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp start_port(_workspace, worker_host, script) when is_binary(worker_host) do
    SSH.start_port(worker_host, script, line: @port_line_bytes)
  end

  defp stream_loop(port, on_message, session_id, timeout_ms, pending_line, summary, recent_lines) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        {summary, recent_lines} = handle_line(line, on_message, session_id, summary, recent_lines)
        stream_loop(port, on_message, session_id, timeout_ms, "", summary, recent_lines)

      {^port, {:data, {:noeol, chunk}}} ->
        stream_loop(
          port,
          on_message,
          session_id,
          timeout_ms,
          pending_line <> to_string(chunk),
          summary,
          recent_lines
        )

      {^port, {:exit_status, 0}} ->
        {:ok, summary}

      {^port, {:exit_status, status}} ->
        output =
          recent_lines
          |> Enum.reverse()
          |> Enum.join("\n")
          |> summarize_text(@error_output_byte_limit)

        {:error, {:claude_cli_exit, status, output}}
    after
      timeout_ms ->
        {:error, :claude_cli_timeout}
    end
  end

  defp initial_summary do
    %{last_text: "", cumulative_usage: %{}, result_payload: nil, claude_session_id: nil}
  end

  defp append_resume_flag(command, resume_id) when is_binary(resume_id) and resume_id != "" do
    "#{command} --resume #{shell_escape(resume_id)}"
  end

  defp append_resume_flag(command, _resume_id), do: command

  defp handle_line("", _on_message, _session_id, summary, recent_lines) do
    {summary, recent_lines}
  end

  defp handle_line(line, on_message, session_id, summary, recent_lines) do
    recent_lines = [line | recent_lines] |> Enum.take(@recent_lines_kept)

    case Jason.decode(line) do
      {:ok, %{"type" => type} = payload} when is_binary(type) ->
        summary = handle_claude_event(type, payload, on_message, session_id, summary)
        {summary, recent_lines}

      {:ok, payload} ->
        emit_message(on_message, :other_message, %{
          payload: payload,
          raw: line,
          session_id: session_id
        })

        {summary, recent_lines}

      {:error, _reason} ->
        log_non_json_stream_line(line)
        {summary, recent_lines}
    end
  end

  defp handle_claude_event("system", payload, on_message, session_id, summary) do
    claude_session_id = Map.get(payload, "session_id")

    emit_message(on_message, :system_init, %{
      payload: payload,
      session_id: session_id,
      claude_session_id: claude_session_id
    })

    %{summary | claude_session_id: claude_session_id || summary.claude_session_id}
  end

  defp handle_claude_event("assistant", payload, on_message, session_id, summary) do
    message = Map.get(payload, "message") || %{}
    message_usage = Map.get(message, "usage")
    text = assistant_text(message) || summary.last_text

    cumulative_usage =
      summary.cumulative_usage
      |> accumulate_usage(message_usage)
      |> with_total_tokens()

    emit_message(on_message, :assistant_message, %{
      payload: payload,
      session_id: session_id,
      usage: cumulative_usage,
      message_usage: message_usage,
      message_summary: summarize_text(text, @assistant_summary_limit)
    })

    %{summary | last_text: text, cumulative_usage: cumulative_usage}
  end

  defp handle_claude_event("user", payload, on_message, session_id, summary) do
    emit_message(on_message, :tool_result, %{
      payload: payload,
      session_id: session_id
    })

    summary
  end

  defp handle_claude_event("result", payload, on_message, session_id, summary) do
    result_usage = Map.get(payload, "usage")

    cumulative_usage =
      if is_map(result_usage) do
        summary.cumulative_usage
        |> Map.merge(result_usage, fn _k, _existing, replacement -> replacement end)
        |> with_total_tokens()
      else
        summary.cumulative_usage
      end

    claude_session_id =
      Map.get(payload, "session_id") || summary.claude_session_id

    emit_message(on_message, :result, %{
      payload: payload,
      session_id: session_id,
      usage: cumulative_usage,
      claude_session_id: claude_session_id
    })

    %{
      summary
      | result_payload: payload,
        cumulative_usage: cumulative_usage,
        claude_session_id: claude_session_id
    }
  end

  defp handle_claude_event(_other_type, payload, on_message, session_id, summary) do
    emit_message(on_message, :other_message, %{
      payload: payload,
      session_id: session_id
    })

    summary
  end

  defp accumulate_usage(cumulative, %{} = new_usage) do
    Map.merge(cumulative, new_usage, fn
      _key, prev, next when is_integer(prev) and is_integer(next) -> prev + next
      _key, _prev, next -> next
    end)
  end

  defp accumulate_usage(cumulative, _new_usage), do: cumulative

  defp with_total_tokens(usage) when is_map(usage) do
    parts =
      ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
      |> Enum.map(&Map.get(usage, &1, 0))
      |> Enum.filter(&is_integer/1)

    total = Enum.sum(parts)
    Map.put(usage, "total_tokens", total)
  end

  defp assistant_text(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp assistant_text(_message), do: nil

  defp summarize_text(text, limit) when is_binary(text) and is_integer(limit) do
    if byte_size(text) > limit do
      binary_part(text, 0, limit) <> "...<truncated>"
    else
      text
    end
  end

  defp summarize_text(nil, _limit), do: ""

  defp summarize_text(text, limit) do
    text
    |> inspect(printable_limit: limit)
    |> summarize_text(limit)
  end

  defp log_non_json_stream_line(line) do
    trimmed =
      line
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if trimmed != "" do
      if String.match?(trimmed, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{trimmed}")
      else
        Logger.debug("Claude stream output: #{trimmed}")
      end
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
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
