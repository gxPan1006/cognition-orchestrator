defmodule Cognition.ClaudeSessions do
  @moduledoc """
  Discover Claude Code session transcripts (`.jsonl`) for workspaces managed by
  Cognition. Used by the project runtime dashboard so operators can find and
  resume historical Claude sessions without remembering their on-disk paths.

  Claude Code stores transcripts under `~/.claude/projects/<encoded-cwd>/<id>.jsonl`
  where the encoded cwd replaces every `/` with `-`.
  """

  require Logger

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
          claude_dir: Path.t(),
          sessions: [session()]
        }

  @doc """
  Return Claude sessions grouped by workspace subdirectory of `workspace_root`.

  Skips workspaces that have no on-disk Claude session directory. The returned
  list is sorted alphabetically by `issue_identifier` so the rendered ordering
  is stable across refreshes.

  Accepts `:claude_projects_root` to override the default `~/.claude/projects`
  location (mainly used by tests, since the VM caches `$HOME` at boot).
  """
  @spec list(Path.t(), keyword()) :: [workspace_sessions()]
  def list(workspace_root, opts \\ []) when is_binary(workspace_root) do
    claude_root = Keyword.get(opts, :claude_projects_root, claude_projects_root())

    case File.ls(workspace_root) do
      {:ok, names} ->
        names
        |> Enum.filter(&workspace_subdir?(workspace_root, &1))
        |> Enum.map(fn name -> build_workspace_entry(workspace_root, name, claude_root) end)
        |> Enum.reject(&(&1.sessions == []))
        |> Enum.sort_by(& &1.issue_identifier)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Encode a filesystem path the same way Claude Code does when locating session
  files under `~/.claude/projects/`.
  """
  @spec encode_path(Path.t()) :: String.t()
  def encode_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("/", "-")
  end

  @doc """
  Convenience: returns the shell command an operator can paste in a terminal to
  resume the given session.
  """
  @spec resume_command(Path.t(), String.t()) :: String.t()
  def resume_command(workspace, session_id) when is_binary(workspace) and is_binary(session_id) do
    "cd #{shell_escape(workspace)} && claude --resume #{session_id}"
  end

  defp workspace_subdir?(root, name) do
    path = Path.join(root, name)
    File.dir?(path) and not String.starts_with?(name, ".")
  end

  defp build_workspace_entry(root, name, claude_root) do
    workspace = Path.join(root, name)
    claude_dir = Path.join(claude_root, encode_path(workspace))

    %{
      issue_identifier: name,
      workspace: workspace,
      claude_dir: claude_dir,
      sessions: collect_sessions(claude_dir)
    }
  end

  defp claude_projects_root do
    case System.user_home() do
      home when is_binary(home) -> Path.join(home, ".claude/projects")
      _ -> Path.expand("~/.claude/projects")
    end
  end

  defp collect_sessions(claude_dir) do
    case File.ls(claude_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.flat_map(fn name -> read_session(claude_dir, name) end)
        |> Enum.sort_by(& &1.modified_at, {:desc, DateTime})

      _ ->
        []
    end
  end

  defp read_session(dir, name) do
    full = Path.join(dir, name)

    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        id = Path.rootname(name)

        [
          %{
            id: id,
            path: full,
            modified_at: DateTime.from_unix!(mtime),
            byte_size: size,
            event_count: count_lines(full)
          }
        ]

      _ ->
        []
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
