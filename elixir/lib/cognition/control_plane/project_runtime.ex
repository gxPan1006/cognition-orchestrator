defmodule Cognition.ControlPlane.ProjectRuntime do
  @moduledoc """
  Start, stop, and restart a project's dedicated Cognition runtime by driving its
  tmux session and probing the dashboard port.
  """

  require Logger

  @port_wait_ms 30_000
  @port_check_interval_ms 500
  @port_connect_timeout_ms 200

  @type entry :: map()
  @type result :: {:ok, %{url: String.t(), warnings: [String.t()]}} | {:error, String.t()}

  @doc """
  Start (or force-restart) the runtime for `entry`. Idempotent: existing tmux
  sessions of the same name are killed first.
  """
  @spec start(entry()) :: result()
  def start(%{tmux_session: session, runner_path: runner, project_path: project_path, port: port} = entry) do
    with :ok <- validate_runtime_files(entry),
         {:ok, tmux} <- tmux_executable(),
         {:ok, linear_api_key} <- linear_api_key(),
         :ok <- ignore_error(tmux, ["kill-session", "-t", session]),
         :ok <- run_command(tmux, ["new-session", "-d", "-s", session, "-c", project_path, "/bin/zsh"]),
         :ok <- run_command(tmux, ["set-environment", "-t", session, "LINEAR_API_KEY", linear_api_key]),
         :ok <- maybe_set_path(tmux, session),
         :ok <- run_command(tmux, ["send-keys", "-t", session, "exec #{shell_quote(runner)}", "C-m"]) do
      listening? = wait_for_port(port)

      {:ok,
       %{
         url: "http://127.0.0.1:#{port}/",
         warnings: runtime_warnings(port, listening?)
       }}
    end
  end

  @spec stop(entry()) :: :ok | {:error, String.t()}
  def stop(%{tmux_session: session, port: port}) do
    case tmux_executable() do
      {:ok, tmux} -> ignore_error(tmux, ["kill-session", "-t", session])
      _ -> :ok
    end

    # Belt-and-suspenders: also TERM any process still listening on the port.
    # Handles runtimes that were started outside the tmux session (e.g. a manual
    # `run-cognition.sh` run before the control plane took over) so Stop still
    # actually frees the port for a subsequent Start.
    kill_port_owner(port)
    :ok
  end

  @spec restart(entry()) :: result()
  def restart(entry) do
    _ = stop(entry)
    start(entry)
  end

  defp validate_runtime_files(entry) do
    cond do
      not File.regular?(entry.workflow_path) ->
        {:error, "Missing WORKFLOW.md at #{entry.workflow_path}"}

      not File.regular?(entry.runner_path) ->
        {:error, "Missing runner script at #{entry.runner_path}"}

      true ->
        :ok
    end
  end

  defp tmux_executable do
    case System.find_executable("tmux") do
      nil -> {:error, "tmux is not installed on PATH"}
      executable -> {:ok, executable}
    end
  end

  defp linear_api_key do
    case System.get_env("LINEAR_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, "LINEAR_API_KEY is not set in the control plane environment"}
    end
  end

  defp maybe_set_path(tmux, session) do
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" ->
        run_command(tmux, ["set-environment", "-t", session, "PATH", path])

      _ ->
        :ok
    end
  end

  defp ignore_error(command, args) do
    _ = System.cmd(command, args, stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp kill_port_owner(port) when is_integer(port) and port > 0 do
    case System.find_executable("lsof") do
      nil -> :ok
      lsof -> terminate_port_listeners(lsof, port)
    end
  rescue
    _ -> :ok
  end

  defp kill_port_owner(_port), do: :ok

  defp terminate_port_listeners(lsof, port) do
    case System.cmd(lsof, ["-tiTCP:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
      {output, status} when status in [0, 1] ->
        output
        |> String.split([" ", "\n"], trim: true)
        |> Enum.flat_map(&parse_pid/1)
        |> Enum.each(&terminate_pid/1)

        :ok

      _ ->
        :ok
    end
  end

  defp parse_pid(pid_str) do
    case Integer.parse(pid_str) do
      {pid, ""} when pid > 0 -> [pid]
      _ -> []
    end
  end

  defp terminate_pid(pid) do
    ignore_error("/bin/kill", ["-TERM", Integer.to_string(pid)])
  end

  defp run_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "tmux command failed (status=#{status}): #{String.trim(output)}"}
    end
  rescue
    error -> {:error, "tmux command crashed: #{Exception.message(error)}"}
  end

  defp wait_for_port(port) when is_integer(port) and port > 0 do
    iterations = div(@port_wait_ms, @port_check_interval_ms)

    Enum.any?(1..iterations, fn _attempt ->
      if port_open?(port) do
        true
      else
        Process.sleep(@port_check_interval_ms)
        false
      end
    end)
  end

  defp wait_for_port(_port), do: false

  defp port_open?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @port_connect_timeout_ms) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp runtime_warnings(_port, true), do: []

  defp runtime_warnings(port, false) do
    ["Runtime was launched, but port #{port} was not listening within #{div(@port_wait_ms, 1_000)} seconds."]
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
