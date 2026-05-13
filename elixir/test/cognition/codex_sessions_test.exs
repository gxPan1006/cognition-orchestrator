defmodule Cognition.CodexSessionsTest do
  use ExUnit.Case, async: false

  alias Cognition.CodexSessions

  setup do
    tmp = Path.join(System.tmp_dir!(), "cognition-codex-sessions-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(tmp, "workspaces")
    codex_home = Path.join(tmp, "codex-home")
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(Path.join(codex_home, "sessions"))

    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, workspace_root: workspace_root, codex_home: codex_home}
  end

  defp seed_rollout(codex_home, date_path, id, cwd, extra_lines) do
    dir = Path.join([codex_home, "sessions"] ++ date_path)
    File.mkdir_p!(dir)

    meta =
      Jason.encode!(%{
        "timestamp" => "2026-05-13T11:00:00.000Z",
        "type" => "session_meta",
        "payload" => %{"id" => id, "cwd" => cwd}
      })

    body = [meta | extra_lines] |> Enum.join("\n")
    path = Path.join(dir, "rollout-2026-05-13T11-00-00-#{id}.jsonl")
    File.write!(path, body <> "\n")
    path
  end

  test "lists workspaces with rollouts grouped by cwd, newest first", %{
    workspace_root: ws_root,
    codex_home: codex_home
  } do
    workspace_a = Path.join(ws_root, "GXP-1") |> Path.expand()
    workspace_b = Path.join(ws_root, "GXP-2") |> Path.expand()
    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)

    seed_rollout(codex_home, ["2026", "05", "13"], "old-aaaa-1111", workspace_a, ["{\"line\":1}"])
    Process.sleep(1100)
    seed_rollout(codex_home, ["2026", "05", "13"], "new-aaaa-2222", workspace_a, ["{\"line\":1}", "{\"line\":2}"])
    seed_rollout(codex_home, ["2026", "05", "13"], "bbbb-3333", workspace_b, [])

    result = CodexSessions.list(ws_root, codex_home: codex_home)

    assert length(result) == 2
    [entry_a, entry_b] = result
    assert entry_a.issue_identifier == "GXP-1"
    assert entry_b.issue_identifier == "GXP-2"

    [first_a, second_a] = entry_a.sessions
    assert first_a.id == "new-aaaa-2222"
    assert first_a.event_count == 3
    assert second_a.id == "old-aaaa-1111"
    assert second_a.event_count == 2

    [session_b] = entry_b.sessions
    assert session_b.id == "bbbb-3333"
    assert session_b.event_count == 1
  end

  test "skips workspaces that have no matching rollouts", %{workspace_root: ws_root, codex_home: codex_home} do
    File.mkdir_p!(Path.join(ws_root, "GXP-NOPE"))

    assert CodexSessions.list(ws_root, codex_home: codex_home) == []
  end

  test "skips hidden workspace dirs like .git", %{workspace_root: ws_root, codex_home: codex_home} do
    File.mkdir_p!(Path.join(ws_root, ".secret"))
    workspace = Path.join(ws_root, "GXP-OK") |> Path.expand()
    File.mkdir_p!(workspace)
    seed_rollout(codex_home, ["2026", "05", "13"], "abc-1234", workspace, [])

    assert [%{issue_identifier: "GXP-OK"}] = CodexSessions.list(ws_root, codex_home: codex_home)
  end

  test "ignores rollouts whose cwd is not under workspace_root", %{
    workspace_root: ws_root,
    codex_home: codex_home
  } do
    workspace = Path.join(ws_root, "GXP-OK") |> Path.expand()
    File.mkdir_p!(workspace)

    seed_rollout(codex_home, ["2026", "05", "13"], "for-known", workspace, [])
    seed_rollout(codex_home, ["2026", "05", "13"], "for-other", "/some/unrelated/path", [])

    [entry] = CodexSessions.list(ws_root, codex_home: codex_home)
    assert entry.issue_identifier == "GXP-OK"
    assert [%{id: "for-known"}] = entry.sessions
  end

  test "ignores rollout files whose first line is not session_meta", %{
    workspace_root: ws_root,
    codex_home: codex_home
  } do
    workspace = Path.join(ws_root, "GXP-OK") |> Path.expand()
    File.mkdir_p!(workspace)

    dir = Path.join([codex_home, "sessions", "2026", "05", "13"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "rollout-2026-05-13T11-00-00-bad.jsonl"), ~s({"type":"event","payload":{}}\n))

    assert CodexSessions.list(ws_root, codex_home: codex_home) == []
  end

  test "resume_command wraps codex resume with shell-escaped workspace" do
    cmd = CodexSessions.resume_command("/tmp/with space", "rollout-id")
    assert cmd =~ "cd '/tmp/with space'"
    assert cmd =~ "codex resume rollout-id"
    assert cmd =~ "CODEX_HOME="
  end

  test "returns [] for a missing workspace root" do
    assert CodexSessions.list("/this/does/not/exist") == []
  end
end
