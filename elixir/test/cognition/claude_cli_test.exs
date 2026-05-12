defmodule Cognition.ClaudeCliTest do
  use Cognition.TestSupport

  alias Cognition.CodingTool.ClaudeCli

  test "claude cli adapter runs the configured command in the issue workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-claude-cli-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GXP-33")
      fake_claude = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude.trace")
      prompt_file = Path.join(test_root, "claude.prompt")

      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf 'cwd=%s\\n' "$(pwd)" > #{shell_string(trace_file)}
      cat > #{shell_string(prompt_file)}
      printf '%s\\n' '{"type":"result","result":"ok"}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        coding_tool_kind: "claude",
        claude_command: shell_string(fake_claude)
      )

      issue = %Issue{
        id: "issue-claude",
        identifier: "GXP-33",
        title: "Claude adapter",
        description: "Run fake Claude",
        state: "In Progress",
        url: "https://example.org/issues/GXP-33",
        labels: ["backend"]
      }

      assert {:ok, session} = ClaudeCli.start_session(workspace)
      on_message = fn message -> send(self(), {:claude_update, message}) end

      assert {:ok, result} =
               ClaudeCli.run_turn(session, "Implement via Claude\n", issue, on_message: on_message)

      assert result.thread_id == session.thread_id
      assert result.turn_id =~ "claude-turn-"
      assert result.session_id =~ session.thread_id

      assert_received {:claude_update, %{event: :session_started, coding_tool: "claude"}}
      assert_received {:claude_update, %{event: :turn_completed, coding_tool: "claude"}}

      assert {:ok, canonical_workspace} = Cognition.PathSafety.canonicalize(workspace)
      assert File.read!(trace_file) == "cwd=#{canonical_workspace}\n"
      assert File.read!(prompt_file) == "Implement via Claude\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "claude cli adapter reports nonzero exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-claude-cli-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GXP-FAIL")
      fake_claude = Path.join(test_root, "fake-claude-fail")

      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      cat >/dev/null
      echo "boom" >&2
      exit 7
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        coding_tool_kind: "claude",
        claude_command: shell_string(fake_claude)
      )

      issue = %Issue{
        id: "issue-claude-fail",
        identifier: "GXP-FAIL",
        title: "Claude adapter failure",
        description: "Run fake Claude",
        state: "In Progress",
        url: "https://example.org/issues/GXP-FAIL",
        labels: ["backend"]
      }

      assert {:ok, session} = ClaudeCli.start_session(workspace)
      on_message = fn message -> send(self(), {:claude_update, message}) end

      assert {:error, {:claude_cli_exit, 7, output}} =
               ClaudeCli.run_turn(session, "fail\n", issue, on_message: on_message)

      assert output =~ "boom"
      assert_received {:claude_update, %{event: :session_started, coding_tool: "claude"}}
      assert_received {:claude_update, %{event: :turn_failed, coding_tool: "claude"}}
    after
      File.rm_rf(test_root)
    end
  end

  defp shell_string(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
