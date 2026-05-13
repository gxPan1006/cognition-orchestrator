defmodule Cognition.ExtensionsTest do
  use Cognition.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Cognition.Linear.Adapter
  alias Cognition.ProjectSetup
  alias Cognition.Tracker.Memory

  @endpoint CognitionWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      process_results = Process.get({__MODULE__, :graphql_results})
      shared_results = Application.get_env(:cognition, :fake_linear_graphql_results)

      case process_results || shared_results do
        [result | rest] ->
          if is_nil(process_results) do
            Application.put_env(:cognition, :fake_linear_graphql_results, rest)
          else
            Process.put({__MODULE__, :graphql_results}, rest)
          end

          result

        _ ->
          Process.get({__MODULE__, :graphql_result}) ||
            Application.get_env(:cognition, :fake_linear_graphql_result)
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:cognition, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:cognition, :linear_client_module)
      else
        Application.put_env(:cognition, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:cognition, CognitionWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:cognition, CognitionWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(Cognition.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(Cognition.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(Cognition.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(Cognition.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:cognition, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:cognition, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert Cognition.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = Cognition.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = Cognition.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = Cognition.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = Cognition.Tracker.create_comment("issue-1", "comment")
    assert :ok = Cognition.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:cognition, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Cognition.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "linear_graphql endpoint proxies to the configured Linear client" do
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Application.delete_env(:cognition, :linear_client_module)
      Application.delete_env(:cognition, :fake_linear_graphql_result)
    end)

    Application.put_env(
      :cognition,
      :fake_linear_graphql_result,
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearGraphqlOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    body = %{
      "query" => "mutation Move($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success } }",
      "variables" => %{"id" => "issue-1", "stateId" => "state-progress"}
    }

    response = json_response(post(build_conn(), "/api/v1/linear/graphql", body), 200)

    assert response == %{"data" => %{"issueUpdate" => %{"success" => true}}}

    assert_received {:graphql_called, query, variables}
    assert query =~ "issueUpdate"
    assert variables == %{"id" => "issue-1", "stateId" => "state-progress"}
  end

  test "linear_graphql endpoint rejects missing query, bad variables, and propagates client errors" do
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Application.delete_env(:cognition, :linear_client_module)
      Application.delete_env(:cognition, :fake_linear_graphql_result)
    end)

    orchestrator_name = Module.concat(__MODULE__, :LinearGraphqlValidationOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(post(build_conn(), "/api/v1/linear/graphql", %{}), 400) ==
             %{
               "error" => %{
                 "code" => "missing_query",
                 "message" => "Request body must include a non-empty `query` string"
               }
             }

    assert json_response(post(build_conn(), "/api/v1/linear/graphql", %{"query" => "   "}), 400) ==
             %{
               "error" => %{
                 "code" => "missing_query",
                 "message" => "Request body must include a non-empty `query` string"
               }
             }

    assert json_response(
             post(build_conn(), "/api/v1/linear/graphql", %{
               "query" => "query { ok }",
               "variables" => "not-an-object"
             }),
             400
           ) ==
             %{
               "error" => %{
                 "code" => "invalid_variables",
                 "message" => "`variables` must be a JSON object when provided"
               }
             }

    assert json_response(get(build_conn(), "/api/v1/linear/graphql"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    Application.put_env(:cognition, :fake_linear_graphql_result, {:error, :missing_linear_api_token})

    assert json_response(
             post(build_conn(), "/api/v1/linear/graphql", %{"query" => "query { ok }"}),
             500
           ) ==
             %{
               "error" => %{
                 "code" => "missing_linear_api_token",
                 "message" => "Cognition has no Linear API token configured"
               }
             }

    Application.put_env(:cognition, :fake_linear_graphql_result, {:error, {:linear_api_status, 503}})

    assert json_response(
             post(build_conn(), "/api/v1/linear/graphql", %{"query" => "query { ok }"}),
             502
           ) ==
             %{
               "error" => %{
                 "code" => "linear_api_status",
                 "message" => "Linear GraphQL responded with HTTP 503"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "project setup prepares a project-local workflow and runner" do
    project_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-project-setup-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(project_root)
    {project_root, 0} = System.cmd("pwd", ["-P"], cd: project_root)
    project_root = String.trim(project_root)
    File.write!(Path.join(project_root, "package-lock.json"), "{}\n")
    assert {_output, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: project_root)

    on_exit(fn ->
      Application.delete_env(:cognition, :cognition_elixir_dir)
      Application.delete_env(:cognition, :fake_linear_graphql_result)
      Application.delete_env(:cognition, :project_runtime_starter)
      File.rm_rf(project_root)
      File.rm_rf("#{project_root}-workspaces")
    end)

    Application.put_env(:cognition, :cognition_elixir_dir, "/opt/cognition/elixir")
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    Application.put_env(:cognition, :project_runtime_starter, fn result ->
      {:ok, %{session: "cognition-test-#{result.port}", url: "http://127.0.0.1:#{result.port}/", warnings: []}}
    end)

    Application.put_env(
      :cognition,
      :fake_linear_graphql_result,
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{
                 "slugId" => "project-123",
                 "url" => "https://linear.app/project/project-123/issues",
                 "teams" => %{"nodes" => [%{"id" => "team-1"}]}
               }
             ]
           }
         }
       }}
    )

    assert {:ok, result} =
             ProjectSetup.prepare(%{
               "project_path" => project_root,
               "project_slug" => "project-123",
               "coding_tool" => "claude",
               "clone_source" => "local",
               "port" => "4111"
             })

    assert result.project_path == project_root
    assert result.workspace_root == "#{project_root}-workspaces"
    assert result.clone_source == "local:#{project_root}"
    assert result.coding_tool == "claude"
    refute result.linear_project_created
    assert result.runtime_started
    assert result.runtime_session == "cognition-test-4111"
    assert result.runtime_url == "http://127.0.0.1:4111/"
    assert File.exists?(result.workflow_path)
    assert File.exists?(result.runner_path)

    workflow = File.read!(result.workflow_path)
    assert workflow =~ "project_slug: \"project-123\""
    assert workflow =~ "coding_tool:\n  kind: claude"
    assert workflow =~ "git clone '#{project_root}' ."
    assert workflow =~ "npm ci"

    runner = File.read!(result.runner_path)
    assert runner =~ "cd '/opt/cognition/elixir'"
    assert runner =~ "--port 4111"
    assert runner =~ result.workflow_path
  end

  test "project setup reuses existing project-local workflow slug when slug is blank" do
    project_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-project-setup-existing-slug-#{System.unique_integer([:positive])}"
      )

    cognition_dir = Path.join(project_root, ".cognition")
    File.mkdir_p!(cognition_dir)
    {project_root, 0} = System.cmd("pwd", ["-P"], cd: project_root)
    project_root = String.trim(project_root)
    assert {_output, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: project_root)

    File.write!(Path.join(project_root, ".cognition/WORKFLOW.md"), """
    ---
    tracker:
      kind: linear
      project_slug: saved-linear-slug
    ---
    Existing workflow.
    """)

    on_exit(fn ->
      Application.delete_env(:cognition, :cognition_elixir_dir)
      Application.delete_env(:cognition, :fake_linear_graphql_result)
      Application.delete_env(:cognition, :project_runtime_starter)
      File.rm_rf(project_root)
      File.rm_rf("#{project_root}-workspaces")
    end)

    Application.put_env(:cognition, :cognition_elixir_dir, "/opt/cognition/elixir")
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    Application.put_env(:cognition, :project_runtime_starter, fn result ->
      {:ok, %{session: "cognition-test-#{result.port}", url: "http://127.0.0.1:#{result.port}/", warnings: []}}
    end)

    Application.put_env(
      :cognition,
      :fake_linear_graphql_result,
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{
                 "slugId" => "saved-linear-slug",
                 "url" => "https://linear.app/project/saved-linear-slug/issues",
                 "teams" => %{"nodes" => [%{"id" => "team-1"}]}
               }
             ]
           }
         }
       }}
    )

    assert {:ok, result} =
             ProjectSetup.prepare(%{
               "project_path" => project_root,
               "project_slug" => "",
               "coding_tool" => "codex",
               "clone_source" => "local",
               "port" => "4113"
             })

    assert_receive {:graphql_called, _query, %{slugId: "saved-linear-slug"}}
    assert result.project_slug == "saved-linear-slug"
    refute result.linear_project_created
  end

  test "project setup initialises a Git repo when the chosen folder is not a worktree" do
    project_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-project-setup-no-git-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(project_root)
    {project_root, 0} = System.cmd("pwd", ["-P"], cd: project_root)
    project_root = String.trim(project_root)

    on_exit(fn ->
      Application.delete_env(:cognition, :cognition_elixir_dir)
      Application.delete_env(:cognition, :fake_linear_graphql_result)
      Application.delete_env(:cognition, :project_runtime_starter)
      File.rm_rf(project_root)
      File.rm_rf("#{project_root}-workspaces")
    end)

    Application.put_env(:cognition, :cognition_elixir_dir, "/opt/cognition/elixir")
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    Application.put_env(:cognition, :project_runtime_starter, fn result ->
      {:ok, %{session: "cognition-test-#{result.port}", url: "http://127.0.0.1:#{result.port}/", warnings: []}}
    end)

    Application.put_env(
      :cognition,
      :fake_linear_graphql_result,
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{
                 "slugId" => "auto-init-project",
                 "url" => "https://linear.app/project/auto-init-project/issues",
                 "teams" => %{"nodes" => [%{"id" => "team-1"}]}
               }
             ]
           }
         }
       }}
    )

    refute File.exists?(Path.join(project_root, ".git"))

    assert {:ok, result} =
             ProjectSetup.prepare(%{
               "project_path" => project_root,
               "project_slug" => "auto-init-project",
               "coding_tool" => "codex",
               "clone_source" => "local",
               "port" => "4114"
             })

    assert File.dir?(Path.join(project_root, ".git"))
    assert result.project_path == project_root
    assert result.runtime_started

    assert Enum.any?(result.warnings, fn warning ->
             warning =~ "Initialised a Git repository"
           end)
  end

  test "ProjectSetup.next_free_port/0 skips ports already taken by registered runtimes" do
    refute Process.whereis(Cognition.ControlPlane.Registry),
           "Registry should not be running before this test starts"

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "cognition-port-picker-#{System.unique_integer([:positive])}.json"
      )

    {:ok, pid} =
      Cognition.ControlPlane.Registry.start_link(
        name: Cognition.ControlPlane.Registry,
        persistence_path: tmp_path
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(tmp_path)
    end)

    {:ok, _entry} =
      Cognition.ControlPlane.Registry.register(%{
        name: "demo",
        project_path: "/tmp/demo",
        workflow_path: "/tmp/demo/.cognition/WORKFLOW.md",
        runner_path: "/tmp/demo/.cognition/run-cognition.sh",
        tmux_session: "cognition-demo-4000",
        port: 4000,
        coding_tool: "codex",
        workspace_root: "/tmp/demo-workspaces"
      })

    picked = ProjectSetup.next_free_port(4000)
    assert is_integer(picked) and picked > 0
    refute picked == 4000
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    Application.put_env(:cognition, :runtime_mode, :project)
    on_exit(fn -> Application.delete_env(:cognition, :runtime_mode) end)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Cognition Runtime"
    assert html =~ "Agent Activity"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Live"
    assert html =~ "Offline"
    refute html =~ "Project onboarding"
    refute html =~ "Directory browser"
    refute html =~ "Prepare and start"
    assert html =~ "Copy ID"
    assert html =~ "Agent update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard project onboarding form prepares runtime files" do
    orchestrator_name = Module.concat(__MODULE__, :ProjectSetupDashboardOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    project_root =
      Path.join(
        System.tmp_dir!(),
        "cognition-dashboard-project-setup-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(project_root)
    {project_root, 0} = System.cmd("pwd", ["-P"], cd: project_root)
    project_root = String.trim(project_root)
    assert {_output, 0} = System.cmd("git", ["init", "--initial-branch=main"], cd: project_root)

    Application.put_env(:cognition, :runtime_mode, :control_plane)

    on_exit(fn ->
      Application.delete_env(:cognition, :runtime_mode)
      Application.delete_env(:cognition, :cognition_elixir_dir)
      Application.delete_env(:cognition, :fake_linear_graphql_results)
      Application.delete_env(:cognition, :project_runtime_starter)
      Application.delete_env(:cognition, :project_folder_picker)
      File.rm_rf(project_root)
      File.rm_rf("#{project_root}-workspaces")
    end)

    Application.put_env(:cognition, :cognition_elixir_dir, "/opt/cognition/elixir")
    Application.put_env(:cognition, :linear_client_module, FakeLinearClient)

    Application.put_env(:cognition, :project_runtime_starter, fn result ->
      {:ok, %{session: "cognition-test-#{result.port}", url: "http://127.0.0.1:#{result.port}/", warnings: []}}
    end)

    Application.put_env(
      :cognition,
      :fake_linear_graphql_results,
      [
        {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}},
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [
                 %{
                   "slugId" => "project",
                   "teams" => %{"nodes" => [%{"id" => "team-1"}]}
                 }
               ]
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "projectCreate" => %{
               "success" => true,
               "project" => %{
                 "slugId" => "created-project",
                 "url" => "https://linear.app/project/created-project/issues"
               }
             }
           }
         }}
      ]
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    Application.put_env(:cognition, :project_folder_picker, fn _start_path -> {:ok, project_root} end)

    changed_html =
      view
      |> element("form[phx-change='validate_project_setup']")
      |> render_change(%{
        "project_setup" => %{
          "project_path" => "",
          "project_slug" => "",
          "coding_tool" => "claude",
          "clone_source" => "local",
          "port" => "4112",
          "workspace_root" => ""
        }
      })

    assert changed_html =~ ~s(<option value="claude" selected)
    assert changed_html =~ ~s(<option value="local" selected)

    picker_html = render_click(view, "choose_project_folder")
    assert picker_html =~ project_root
    assert picker_html =~ ~s(<option value="claude" selected)
    assert picker_html =~ ~s(<option value="local" selected)

    browser_html = render_click(view, "browse_project_path", %{"path" => Path.dirname(project_root)})
    assert browser_html =~ Path.basename(project_root)
    assert browser_html =~ ~s(<option value="claude" selected)
    assert browser_html =~ ~s(<option value="local" selected)

    selected_html = render_click(view, "select_project_path", %{"path" => project_root})
    assert selected_html =~ project_root
    assert selected_html =~ ~s(<option value="claude" selected)
    assert selected_html =~ ~s(<option value="local" selected)

    pending_html =
      view
      |> element("form[phx-submit='prepare_project']")
      |> render_submit(%{
        "project_setup" => %{
          "project_path" => project_root,
          "project_slug" => "",
          "coding_tool" => "codex",
          "clone_source" => "local",
          "port" => "4112",
          "workspace_root" => ""
        }
      })

    assert pending_html =~ "Preparing"
    assert pending_html =~ "setup-pending"

    html = render_async(view)

    workflow_path = Path.join(project_root, ".cognition/WORKFLOW.md")
    runner_path = Path.join(project_root, ".cognition/run-cognition.sh")

    assert html =~ "Clone source"
    assert html =~ "local:#{project_root}"
    assert html =~ "created · created-project"
    assert html =~ "http://127.0.0.1:4112/"
    assert html =~ "cognition-test-4112"
    refute html =~ "setup-pending"
    assert File.exists?(workflow_path)
    assert File.exists?(runner_path)
    assert File.read!(workflow_path) =~ "project_slug: \"created-project\""
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :cognition
      |> Application.get_env(CognitionWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:cognition, CognitionWeb.Endpoint, endpoint_config)
    start_supervised!({CognitionWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(Cognition.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
