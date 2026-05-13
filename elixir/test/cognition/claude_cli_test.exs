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

  test "claude cli adapter streams assistant + result events with cumulative usage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-claude-cli-stream-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GXP-STREAM")
      fake_claude = Path.join(test_root, "fake-claude-stream")

      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      cat >/dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-real-1"}'
      printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}],"usage":{"input_tokens":10,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":2}},"session_id":"claude-real-1"}'
      printf '%s\\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"session_id":"claude-real-1"}'
      printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":12,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":2}},"session_id":"claude-real-1"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"result":"Done","session_id":"claude-real-1","total_cost_usd":0.001,"usage":{"input_tokens":22,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":4}}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        coding_tool_kind: "claude",
        claude_command: shell_string(fake_claude)
      )

      issue = %Issue{
        id: "issue-claude-stream",
        identifier: "GXP-STREAM",
        title: "Stream events",
        description: "Stream",
        state: "In Progress",
        url: "https://example.org/issues/GXP-STREAM",
        labels: ["backend"]
      }

      assert {:ok, session} = ClaudeCli.start_session(workspace)
      on_message = fn message -> send(self(), {:claude_update, message}) end

      assert {:ok, _result} =
               ClaudeCli.run_turn(session, "stream please\n", issue, on_message: on_message)

      assert_received {:claude_update, %{event: :session_started}}
      assert_received {:claude_update, %{event: :system_init, claude_session_id: "claude-real-1"}}

      assert_received {:claude_update,
                       %{
                         event: :assistant_message,
                         usage: first_usage,
                         message_summary: "Hello"
                       }}

      assert first_usage["input_tokens"] == 10
      assert first_usage["output_tokens"] == 3
      assert first_usage["total_tokens"] == 15

      assert_received {:claude_update, %{event: :tool_result}}

      assert_received {:claude_update,
                       %{
                         event: :assistant_message,
                         usage: second_usage,
                         message_summary: "Done"
                       }}

      assert second_usage["input_tokens"] == 22
      assert second_usage["output_tokens"] == 7
      assert second_usage["total_tokens"] == 33

      assert_received {:claude_update, %{event: :result, usage: result_usage}}
      assert result_usage["input_tokens"] == 22
      assert result_usage["output_tokens"] == 7

      assert_received {:claude_update, %{event: :turn_completed, usage: final_usage}}
      assert final_usage["input_tokens"] == 22
      assert final_usage["output_tokens"] == 7
      assert final_usage["total_tokens"] == 33
    after
      File.rm_rf(test_root)
    end
  end

  test "claude cli adapter passes --resume on continuation turns within the same session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-claude-cli-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "GXP-RESUME")
      fake_claude = Path.join(test_root, "fake-claude-resume")
      trace_file = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf 'ARGS:%s\\n' " $*" >> #{shell_string(trace_file)}
      cat >/dev/null
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-real-resume-id"}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"claude-real-resume-id","usage":{"input_tokens":1,"output_tokens":1}}'
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        coding_tool_kind: "claude",
        claude_command: shell_string(fake_claude)
      )

      issue = %Issue{
        id: "issue-resume",
        identifier: "GXP-RESUME",
        title: "Resume",
        description: "Resume me",
        state: "In Progress",
        url: "https://example.org/issues/GXP-RESUME",
        labels: []
      }

      assert {:ok, session} = ClaudeCli.start_session(workspace)
      on_message = fn _ -> :ok end

      try do
        assert {:ok, first} =
                 ClaudeCli.run_turn(session, "first turn\n", issue, on_message: on_message)

        assert first.claude_session_id == "claude-real-resume-id"

        assert {:ok, second} =
                 ClaudeCli.run_turn(session, "second turn\n", issue, on_message: on_message)

        assert second.claude_session_id == "claude-real-resume-id"
      after
        ClaudeCli.stop_session(session)
      end

      trace_lines = trace_file |> File.read!() |> String.split("\n", trim: true)

      assert length(trace_lines) == 2
      [first_invocation, second_invocation] = trace_lines

      refute first_invocation =~ "--resume"
      assert second_invocation =~ "--resume claude-real-resume-id"
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
