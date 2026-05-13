defmodule Cognition.ClaudeSessionsTest do
  use ExUnit.Case, async: false

  alias Cognition.ClaudeSessions

  setup do
    tmp = Path.join(System.tmp_dir!(), "cognition-claude-sessions-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    claude_root = Path.join(tmp, "claude/projects")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(claude_root)

    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, workspace_root: workspace_root, claude_root: claude_root}
  end

  defp seed_session(claude_root, workspace, session_id, lines) do
    encoded = ClaudeSessions.encode_path(workspace)
    dir = Path.join(claude_root, encoded)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{session_id}.jsonl"), Enum.map_join(lines, "\n", & &1) <> "\n")
  end

  test "lists workspaces with their session jsonls, newest first", %{workspace_root: ws_root, claude_root: claude_root} do
    workspace_a = Path.join(ws_root, "GXP-1")
    workspace_b = Path.join(ws_root, "GXP-2")
    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)

    seed_session(claude_root, workspace_a, "aaaa1111-old", ~w[event1 event2])
    Process.sleep(1100)
    seed_session(claude_root, workspace_a, "aaaa1111-new", ~w[event1 event2 event3])
    seed_session(claude_root, workspace_b, "bbbb2222", ~w[only-one])

    result = ClaudeSessions.list(ws_root, claude_projects_root: claude_root)

    assert length(result) == 2
    [entry_a, entry_b] = result
    assert entry_a.issue_identifier == "GXP-1"
    assert entry_b.issue_identifier == "GXP-2"

    [first_session_a, second_session_a] = entry_a.sessions
    assert first_session_a.id == "aaaa1111-new"
    assert first_session_a.event_count == 3
    assert second_session_a.id == "aaaa1111-old"
    assert second_session_a.event_count == 2

    [session_b] = entry_b.sessions
    assert session_b.event_count == 1
  end

  test "skips workspaces without a matching claude project dir", %{workspace_root: ws_root, claude_root: claude_root} do
    File.mkdir_p!(Path.join(ws_root, "GXP-NOPE"))

    assert ClaudeSessions.list(ws_root, claude_projects_root: claude_root) == []
  end

  test "skips hidden directories like .git inside workspace root", %{workspace_root: ws_root, claude_root: claude_root} do
    File.mkdir_p!(Path.join(ws_root, ".secret"))
    workspace = Path.join(ws_root, "GXP-OK")
    File.mkdir_p!(workspace)
    seed_session(claude_root, workspace, "sess", ["a"])

    assert [%{issue_identifier: "GXP-OK"}] =
             ClaudeSessions.list(ws_root, claude_projects_root: claude_root)
  end

  test "encode_path replaces slashes the same way Claude Code does" do
    assert ClaudeSessions.encode_path("/Users/me/code/test") == "-Users-me-code-test"
  end

  test "resume_command shell-escapes workspace paths" do
    cmd = ClaudeSessions.resume_command("/tmp/with space", "sess-id")
    assert cmd == "cd '/tmp/with space' && claude --resume sess-id"
  end

  test "returns [] for a missing workspace root" do
    assert ClaudeSessions.list("/this/does/not/exist") == []
  end
end
