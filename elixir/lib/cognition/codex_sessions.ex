defmodule Cognition.CodexSessions do
  @moduledoc """
  Discover Codex rollout transcripts (`rollout-*.jsonl`) written for workspaces
  managed by Cognition. Used by the project runtime dashboard so operators can
  find Codex rollouts without remembering their on-disk paths.

  Codex stores rollouts under `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`.
  The first line of each file is a `session_meta` JSON event whose `cwd` field
  identifies the working directory of the Codex run. We match those `cwd`
  values against the subdirectories of the project's `workspace_root`.
  """

  require Logger

  @default_codex_home_subpath ".cognition-codex-runtime"

  @type session :: %{
          id: String.t(),
          path: Path.t(),
          modified_at: DateTime.t(),
          byte_size: non_neg_integer(),
          event_count: non_neg_integer()
        }

  @type workspace_sessions :: %{
          issue_identifier: String.t(),
          workspace: Path.t(),
          sessions_dir: Path.t(),
          sessions: [session()]
        }

  @doc """
  Return Codex sessions grouped by workspace subdirectory of `workspace_root`.

  Scans `$CODEX_HOME/sessions/**/rollout-*.jsonl`, reads each file's
  `session_meta` event, and groups by the `cwd` field. Only entries whose
  `cwd` resolves to a subdirectory of `workspace_root` are included.

  Skips workspaces with no on-disk rollouts. Sorted alphabetically by
  `issue_identifier` for stable rendering.

  Accepts `:codex_home` to override the default Codex runtime location
  (mainly used by tests).
  """
  @spec list(Path.t(), keyword()) :: [workspace_sessions()]
  def list(workspace_root, opts \\ []) when is_binary(workspace_root) do
    codex_home = Keyword.get(opts, :codex_home, codex_home())
    sessions_root = Path.join(codex_home, "sessions")

    case File.ls(workspace_root) do
      {:ok, names} ->
        workspaces =
          names
          |> Enum.filter(&workspace_subdir?(workspace_root, &1))
          |> Enum.map(&%{name: &1, path: Path.expand(Path.join(workspace_root, &1))})

        sessions_by_cwd = sessions_by_cwd(sessions_root)

        workspaces
        |> Enum.map(fn ws ->
          %{
            issue_identifier: ws.name,
            workspace: ws.path,
            sessions_dir: sessions_root,
            sessions: Map.get(sessions_by_cwd, ws.path, [])
          }
        end)
        |> Enum.reject(&(&1.sessions == []))
        |> Enum.sort_by(& &1.issue_identifier)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Convenience: returns a shell command an operator can paste in a terminal to
  resume the given rollout. Codex resumes via `codex resume <rollout-id>`.
  """
  @spec resume_command(Path.t(), String.t()) :: String.t()
  def resume_command(workspace, rollout_id) when is_binary(workspace) and is_binary(rollout_id) do
    "cd #{shell_escape(workspace)} && CODEX_HOME=#{shell_escape(codex_home())} codex resume #{rollout_id}"
  end

  @doc false
  @spec codex_home() :: Path.t()
  def codex_home do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" -> Path.expand(home)
      _ -> Path.join(System.user_home!(), @default_codex_home_subpath)
    end
  end

  defp workspace_subdir?(root, name) do
    path = Path.join(root, name)
    File.dir?(path) and not String.starts_with?(name, ".")
  end

  defp sessions_by_cwd(sessions_root) do
    rollout_paths(sessions_root)
    |> Enum.flat_map(&read_session_for_indexing/1)
    |> Enum.group_by(& &1.cwd, &Map.delete(&1, :cwd))
    |> Map.new(fn {cwd, sessions} ->
      {cwd, Enum.sort_by(sessions, & &1.modified_at, {:desc, DateTime})}
    end)
  end

  defp rollout_paths(sessions_root) do
    case File.exists?(sessions_root) do
      true ->
        Path.wildcard(Path.join([sessions_root, "**", "rollout-*.jsonl"]))

      false ->
        []
    end
  end

  defp read_session_for_indexing(path) do
    with {:ok, %File.Stat{size: size, mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, first_line} <- first_line(path),
         {:ok, %{"type" => "session_meta", "payload" => payload}} when is_map(payload) <-
           decode(first_line),
         id when is_binary(id) <- Map.get(payload, "id"),
         cwd when is_binary(cwd) <- Map.get(payload, "cwd") do
      [
        %{
          id: id,
          cwd: Path.expand(cwd),
          path: path,
          modified_at: DateTime.from_unix!(mtime),
          byte_size: size,
          event_count: count_lines(path)
        }
      ]
    else
      _ -> []
    end
  end

  defp first_line(path) do
    case File.open(path, [:read, :binary], fn io -> IO.read(io, :line) end) do
      {:ok, :eof} -> {:error, :empty}
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> :error
    end
  end

  defp count_lines(path) do
    path
    |> File.stream!()
    |> Enum.count()
  rescue
    _ -> 0
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
