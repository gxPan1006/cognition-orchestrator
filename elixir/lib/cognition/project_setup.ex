defmodule Cognition.ProjectSetup do
  @moduledoc """
  Prepares and launches project-local Cognition runtimes for Git worktrees.
  """

  alias Cognition.Config
  alias Cognition.ControlPlane.ProjectRuntime

  @default_port_start 4000
  @valid_tools ~w(codex claude)
  @valid_clone_sources ~w(auto local origin)

  @project_lookup_query """
  query CognitionProjectSetupProject($slugId: String!) {
    projects(filter: {slugId: {eq: $slugId}}, first: 1) {
      nodes {
        id
        name
        slugId
        url
        teams {
          nodes {
            id
            key
            name
          }
        }
      }
    }
  }
  """

  @default_team_query """
  query CognitionProjectSetupDefaultTeam {
    teams(first: 1) {
      nodes {
        id
        key
        name
      }
    }
  }
  """

  @project_create_mutation """
  mutation CognitionProjectSetupCreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project {
        id
        name
        slugId
        url
        teams {
          nodes {
            id
            key
            name
          }
        }
      }
    }
  }
  """

  defstruct [
    :project_name,
    :project_path,
    :workflow_path,
    :workspace_root,
    :logs_root,
    :runner_path,
    :clone_source,
    :coding_tool,
    :project_slug,
    :linear_project_created,
    :linear_project_url,
    :port,
    :command,
    :runtime_session,
    :runtime_url,
    runtime_started: false,
    warnings: []
  ]

  @type t :: %__MODULE__{
          project_name: String.t(),
          project_path: Path.t(),
          workflow_path: Path.t(),
          workspace_root: Path.t(),
          logs_root: Path.t(),
          runner_path: Path.t(),
          clone_source: String.t(),
          coding_tool: String.t(),
          project_slug: String.t(),
          linear_project_created: boolean(),
          linear_project_url: String.t() | nil,
          port: pos_integer(),
          command: String.t(),
          runtime_session: String.t() | nil,
          runtime_url: String.t() | nil,
          runtime_started: boolean(),
          warnings: [String.t()]
        }

  @spec prepare(map()) :: {:ok, t()} | {:error, String.t()}
  def prepare(params) when is_map(params) do
    with {:ok, project_path} <- required_path(params, "project_path", "Project folder"),
         {:ok, git_root, git_warnings} <- git_root(project_path),
         {:ok, requested_slug} <- project_slug(params, git_root),
         {:ok, coding_tool} <- coding_tool(params),
         {:ok, port} <- port(params),
         {:ok, clone_source} <- clone_source(params),
         {:ok, workspace_root} <- workspace_root(params, git_root),
         {:ok, clone_command, source_label, source_warnings} <- clone_command(git_root, clone_source),
         {:ok, linear_project} <- ensure_linear_project(requested_slug, git_root),
         {:ok, result} <-
           write_runtime_files(%{
             coding_tool: coding_tool,
             clone_command: clone_command,
             clone_source: source_label,
             linear_project: linear_project,
             project_path: git_root,
             port: port,
             warnings: git_warnings ++ source_warnings ++ Map.get(linear_project, :warnings, []),
             workspace_root: workspace_root
           }) do
      start_runtime(result)
    end
  end

  def prepare(_params), do: {:error, "Project setup params must be a map."}

  @doc false
  @spec start_tmux_runtime(t()) :: {:ok, map()} | {:error, String.t()}
  def start_tmux_runtime(%__MODULE__{} = result) do
    session = runtime_session_name(result)
    entry = result |> Map.from_struct() |> Map.put(:tmux_session, session)

    case ProjectRuntime.start(entry) do
      {:ok, runtime} -> {:ok, Map.put(runtime, :session, session)}
      {:error, _reason} = error -> error
    end
  end

  defp start_runtime(result) do
    starter = Application.get_env(:cognition, :project_runtime_starter, &__MODULE__.start_tmux_runtime/1)

    case starter.(result) do
      {:ok, runtime} when is_map(runtime) ->
        session = Map.get(runtime, :session) || Map.get(runtime, "session") || runtime_session_name(result)
        url = Map.get(runtime, :url) || Map.get(runtime, "url")
        runtime_warnings = Map.get(runtime, :warnings) || Map.get(runtime, "warnings") || []

        final_result = %{
          result
          | runtime_started: true,
            runtime_session: session,
            runtime_url: url,
            warnings: result.warnings ++ runtime_warnings
        }

        maybe_register(final_result)
        {:ok, final_result}

      {:error, message} ->
        {:error, message}

      other ->
        {:error, "Runtime starter returned an unexpected result: #{inspect(other, limit: 10)}"}
    end
  end

  defp maybe_register(%__MODULE__{} = result) do
    case Process.whereis(Cognition.ControlPlane.Registry) do
      pid when is_pid(pid) ->
        attrs = %{
          name: result.project_name,
          project_path: result.project_path,
          workflow_path: result.workflow_path,
          runner_path: result.runner_path,
          tmux_session: result.runtime_session,
          port: result.port,
          linear_url: result.linear_project_url,
          coding_tool: result.coding_tool,
          workspace_root: result.workspace_root
        }

        Cognition.ControlPlane.Registry.register(attrs)

      _ ->
        :ok
    end
  end

  defp write_runtime_files(opts) do
    project_path = opts.project_path
    project_name = Path.basename(project_path)
    cognition_dir = Path.join(project_path, ".cognition")
    logs_root = Path.join(cognition_dir, "log")
    workflow_path = Path.join(cognition_dir, "WORKFLOW.md")
    runner_path = Path.join(cognition_dir, "run-cognition.sh")

    result = %__MODULE__{
      project_name: project_name,
      project_path: project_path,
      workflow_path: workflow_path,
      workspace_root: opts.workspace_root,
      logs_root: logs_root,
      runner_path: runner_path,
      clone_source: opts.clone_source,
      coding_tool: opts.coding_tool,
      project_slug: opts.linear_project.slug_id,
      linear_project_created: opts.linear_project.created?,
      linear_project_url: opts.linear_project.url,
      port: opts.port,
      command: runner_path,
      warnings: opts.warnings
    }

    with :ok <- mkdir_p(cognition_dir),
         :ok <- mkdir_p(logs_root),
         :ok <- mkdir_p(opts.workspace_root),
         :ok <- write_file(workflow_path, workflow_content(opts)),
         :ok <- write_file(runner_path, runner_content(result)),
         :ok <- chmod_runner(runner_path) do
      {:ok, result}
    end
  end

  defp workflow_content(opts) do
    after_create =
      ([opts.clone_command] ++ setup_commands(opts.project_path))
      |> Enum.join("\n")

    [
      "---",
      "tracker:",
      "  kind: linear",
      "  project_slug: #{yaml_string(opts.linear_project.slug_id)}",
      "  active_states:",
      "    - Todo",
      "    - In Progress",
      "    - Merging",
      "    - Rework",
      "  terminal_states:",
      "    - Closed",
      "    - Cancelled",
      "    - Canceled",
      "    - Duplicate",
      "    - Done",
      "polling:",
      "  interval_ms: 5000",
      "workspace:",
      "  root: #{yaml_string(opts.workspace_root)}",
      "hooks:",
      "  after_create: |",
      indent_block(after_create, 4),
      "agent:",
      "  max_concurrent_agents: 1",
      "  max_turns: 20",
      "coding_tool:",
      "  kind: #{opts.coding_tool}",
      "codex:",
      "  command: CODEX_HOME=~/.cognition-codex-runtime codex --config shell_environment_policy.inherit=all --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=low app-server",
      "  approval_policy: never",
      "  stall_timeout_ms: 180000",
      "  thread_sandbox: danger-full-access",
      "  turn_sandbox_policy:",
      "    type: dangerFullAccess",
      "claude:",
      "  command: claude --print --verbose --output-format stream-json --permission-mode bypassPermissions",
      "  turn_timeout_ms: 3600000",
      "  stall_timeout_ms: 300000",
      "server:",
      "  port: #{opts.port}",
      "---",
      Config.workflow_prompt()
    ]
    |> Enum.join("\n")
    |> then(&(&1 <> "\n"))
  end

  defp runner_content(result) do
    cognition_elixir_dir =
      Application.get_env(:cognition, :cognition_elixir_dir, File.cwd!())
      |> Path.expand()

    [
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "",
      "if [ -z \"${LINEAR_API_KEY:-}\" ]; then",
      "  echo \"Set LINEAR_API_KEY before starting this Cognition runtime.\" >&2",
      "  exit 1",
      "fi",
      "",
      "cd #{shell_quote(cognition_elixir_dir)}",
      "exec mise exec -- ./bin/cognition \\",
      "  --i-understand-that-this-will-be-running-without-the-usual-guardrails \\",
      "  --logs-root #{shell_quote(result.logs_root)} \\",
      "  --port #{result.port} \\",
      "  #{shell_quote(result.workflow_path)}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp setup_commands(project_path) do
    cond do
      File.exists?(Path.join(project_path, "elixir/mix.exs")) ->
        [
          "if command -v mise >/dev/null 2>&1; then",
          "  cd elixir && mise trust && mise exec -- mix deps.get",
          "else",
          "  cd elixir && mix deps.get",
          "fi"
        ]

      File.exists?(Path.join(project_path, "mix.exs")) ->
        [
          "if command -v mise >/dev/null 2>&1; then",
          "  mise trust && mise exec -- mix deps.get",
          "else",
          "  mix deps.get",
          "fi"
        ]

      File.exists?(Path.join(project_path, "pnpm-lock.yaml")) ->
        ["pnpm install"]

      File.exists?(Path.join(project_path, "package-lock.json")) ->
        ["npm ci"]

      File.exists?(Path.join(project_path, "yarn.lock")) ->
        ["yarn install --immutable || yarn install"]

      File.exists?(Path.join(project_path, "uv.lock")) ->
        ["uv sync"]

      true ->
        ["# No dependency bootstrap command was detected for this project."]
    end
  end

  defp clone_command(git_root, "local") do
    {:ok, "git clone #{shell_quote(git_root)} .", "local:#{git_root}", []}
  end

  defp clone_command(git_root, "origin") do
    case git_remote_url(git_root) do
      {:ok, remote_url} ->
        {:ok, "git clone #{shell_quote(remote_url)} .", "origin:#{remote_url}", []}

      :error ->
        {:error, "Selected clone source is origin, but the project has no Git origin remote."}
    end
  end

  defp clone_command(git_root, "auto") do
    case git_remote_url(git_root) do
      {:ok, remote_url} ->
        if local_remote?(remote_url) do
          {:ok, "git clone #{shell_quote(git_root)} .", "local:#{git_root}", ["Git origin is local, so workspace clones will use the selected folder."]}
        else
          {:ok, "git clone #{shell_quote(remote_url)} .", "origin:#{remote_url}", []}
        end

      :error ->
        {:ok, "git clone #{shell_quote(git_root)} .", "local:#{git_root}", ["No Git origin remote was found, so workspace clones will use the selected folder."]}
    end
  end

  defp ensure_linear_project(slug_id, git_root) do
    case fetch_linear_project(slug_id) do
      {:ok, nil} ->
        create_linear_project(slug_id, git_root)

      {:ok, project} ->
        {:ok,
         %{
           slug_id: project["slugId"],
           url: project["url"],
           created?: false,
           warnings: []
         }}

      {:error, reason} ->
        {:error, "Unable to ensure Linear project #{inspect(slug_id)}: #{format_linear_error(reason)}"}
    end
  end

  defp fetch_linear_project(slug_id) do
    with {:ok, response} <- linear_client().graphql(@project_lookup_query, %{slugId: slug_id}) do
      projects = get_in(response, ["data", "projects", "nodes"]) || []

      case projects do
        [project | _] when is_map(project) -> {:ok, project}
        [] -> {:ok, nil}
        _ -> {:error, :invalid_project_lookup_payload}
      end
    end
  end

  defp create_linear_project(slug_id, git_root) do
    with {:ok, team_ids, team_warnings} <- default_linear_team_ids(),
         {:ok, response} <-
           linear_client().graphql(@project_create_mutation, %{
             name: project_name_from_slug(slug_id, git_root),
             teamIds: team_ids
           }),
         true <- get_in(response, ["data", "projectCreate", "success"]) == true,
         project when is_map(project) <- get_in(response, ["data", "projectCreate", "project"]),
         created_slug when is_binary(created_slug) <- project["slugId"] do
      {:ok,
       %{
         slug_id: created_slug,
         url: project["url"],
         created?: true,
         warnings:
           team_warnings ++
             maybe_slug_warning(slug_id, created_slug) ++
             ["Created Linear project #{created_slug} because no project existed for #{slug_id}."]
       }}
    else
      false -> {:error, "Linear projectCreate returned success=false."}
      {:error, reason} -> {:error, "Unable to create Linear project: #{format_linear_error(reason)}"}
      _ -> {:error, "Linear projectCreate returned an unexpected payload."}
    end
  end

  defp default_linear_team_ids do
    configured_slug = Config.settings!().tracker.project_slug

    with slug when is_binary(slug) and slug != "" <- configured_slug,
         {:ok, project} when is_map(project) <- fetch_linear_project(slug),
         team_ids when team_ids != [] <- project_team_ids(project) do
      {:ok, team_ids, []}
    else
      _ -> fallback_linear_team_ids()
    end
  end

  defp fallback_linear_team_ids do
    with {:ok, response} <- linear_client().graphql(@default_team_query, %{}),
         [%{"id" => team_id} | _] when is_binary(team_id) <-
           get_in(response, ["data", "teams", "nodes"]) || [] do
      {:ok, [team_id], ["Using the first available Linear team because no current project team could be resolved."]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_linear_team}
    end
  end

  defp project_team_ids(project) when is_map(project) do
    project
    |> get_in(["teams", "nodes"])
    |> case do
      teams when is_list(teams) ->
        teams
        |> Enum.map(& &1["id"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp maybe_slug_warning(requested_slug, created_slug) when requested_slug == created_slug, do: []

  defp maybe_slug_warning(requested_slug, created_slug) do
    ["Linear returned slug #{created_slug}; generated workflow uses that instead of requested #{requested_slug}."]
  end

  defp linear_client do
    Application.get_env(:cognition, :linear_client_module, Cognition.Linear.Client)
  end

  defp git_root(project_path) do
    case rev_parse_toplevel(project_path) do
      {:ok, root} -> {:ok, root, []}
      {:error, _output} -> init_and_resolve_git_root(project_path)
    end
  rescue
    error -> {:error, "Unable to inspect project Git state: #{Exception.message(error)}"}
  end

  defp init_and_resolve_git_root(project_path) do
    case System.cmd("git", ["-C", project_path, "init", "--quiet"], stderr_to_stdout: true) do
      {_output, 0} -> resolve_initialised_root(project_path)
      {output, _status} -> {:error, "Project folder is not a Git worktree and git init failed: #{String.trim(output)}"}
    end
  end

  defp resolve_initialised_root(project_path) do
    case rev_parse_toplevel(project_path) do
      {:ok, root} ->
        {:ok, root, ["Initialised a Git repository at #{root} because the selected folder was not a worktree yet."]}

      {:error, output} ->
        {:error, "Project folder is not a Git worktree even after git init. #{output}"}
    end
  end

  defp rev_parse_toplevel(project_path) do
    case System.cmd("git", ["-C", project_path, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp git_remote_url(git_root) do
    case System.cmd("git", ["-C", git_root, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} ->
        remote_url = String.trim(output)
        if remote_url == "", do: :error, else: {:ok, remote_url}

      {_output, _status} ->
        :error
    end
  end

  defp local_remote?(remote_url) do
    String.starts_with?(remote_url, ["/", "~/", "file:"]) or
      not String.contains?(remote_url, ["://", "@"])
  end

  defp required_path(params, key, label) do
    with {:ok, value} <- required_text(params, key, label) do
      path = expand_path(value)

      cond do
        not File.exists?(path) ->
          {:error, "#{label} does not exist: #{path}"}

        not File.dir?(path) ->
          {:error, "#{label} must be a directory: #{path}"}

        true ->
          {:ok, path}
      end
    end
  end

  defp required_text(params, key, label) do
    value =
      params
      |> Map.get(key, Map.get(params, String.to_atom(key), ""))
      |> to_string()
      |> String.trim()

    cond do
      value == "" -> {:error, "#{label} is required."}
      String.contains?(value, ["\n", "\r", <<0>>]) -> {:error, "#{label} contains invalid characters."}
      true -> {:ok, value}
    end
  end

  defp project_slug(params, git_root) do
    value =
      params
      |> Map.get("project_slug", Map.get(params, :project_slug, ""))
      |> to_string()
      |> String.trim()

    cond do
      String.contains?(value, ["\n", "\r", <<0>>]) ->
        {:error, "Linear project slug contains invalid characters."}

      value == "" ->
        {:ok, existing_workflow_project_slug(git_root) || slugify(Path.basename(git_root))}

      true ->
        {:ok, slugify(value)}
    end
  end

  defp existing_workflow_project_slug(git_root) do
    workflow_path = Path.join(git_root, ".cognition/WORKFLOW.md")

    with {:ok, content} <- File.read(workflow_path),
         {:ok, front_matter} <- workflow_front_matter(content),
         slug when is_binary(slug) and slug != "" <- get_in(front_matter, ["tracker", "project_slug"]) do
      slug
    else
      _ -> nil
    end
  end

  defp workflow_front_matter(content) do
    lines = String.split(content, ~r/\R/u, trim: false)

    with ["---" | tail] <- lines,
         {front, ["---" | _prompt]} <- Enum.split_while(tail, &(&1 != "---")) do
      front
      |> Enum.join("\n")
      |> YamlElixir.read_from_string()
    else
      _ -> {:ok, %{}}
    end
  end

  defp coding_tool(params) do
    value =
      params
      |> Map.get("coding_tool", Map.get(params, :coding_tool, "codex"))
      |> to_string()
      |> String.trim()

    if value in @valid_tools do
      {:ok, value}
    else
      {:error, "Coding tool must be one of: #{Enum.join(@valid_tools, ", ")}."}
    end
  end

  defp clone_source(params) do
    value =
      params
      |> Map.get("clone_source", Map.get(params, :clone_source, "auto"))
      |> to_string()
      |> String.trim()

    if value in @valid_clone_sources do
      {:ok, value}
    else
      {:error, "Clone source must be one of: #{Enum.join(@valid_clone_sources, ", ")}."}
    end
  end

  defp port(params) do
    value =
      params
      |> Map.get("port", Map.get(params, :port, ""))
      |> to_string()
      |> String.trim()

    case value do
      "" ->
        {:ok, next_free_port()}

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 -> {:ok, port}
          _ -> {:error, "Dashboard port must be a positive integer."}
        end
    end
  end

  @doc """
  Pick the smallest free port at or above `starting_at`, skipping ports that
  are already in use by registered runtimes, the control plane itself, or
  any local listener.
  """
  @spec next_free_port(non_neg_integer()) :: pos_integer()
  def next_free_port(starting_at \\ @default_port_start) do
    picker = Application.get_env(:cognition, :next_free_port_picker)

    cond do
      is_function(picker, 0) -> picker.()
      is_function(picker, 1) -> picker.(starting_at)
      true -> scan_for_free_port(starting_at)
    end
  end

  defp scan_for_free_port(starting_at) do
    used = reserved_ports()

    starting_at
    |> Stream.iterate(&(&1 + 1))
    |> Stream.take(200)
    |> Enum.find(&port_available?(&1, used))
    |> case do
      nil -> starting_at
      port -> port
    end
  end

  defp reserved_ports do
    registry_ports =
      case Process.whereis(Cognition.ControlPlane.Registry) do
        pid when is_pid(pid) ->
          Cognition.ControlPlane.Registry.list()
          |> Enum.map(& &1.port)
          |> Enum.filter(&is_integer/1)

        _ ->
          []
      end

    control_plane_port =
      case bound_control_plane_port() do
        port when is_integer(port) and port > 0 -> [port]
        _ -> []
      end

    MapSet.new(registry_ports ++ control_plane_port)
  end

  defp bound_control_plane_port do
    Cognition.HttpServer.bound_port()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp port_available?(port, used) do
    if MapSet.member?(used, port), do: false, else: bindable?(port)
  end

  defp bindable?(port) do
    case :gen_tcp.listen(port, [:binary, {:ip, {127, 0, 0, 1}}, {:reuseaddr, false}, {:active, false}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp workspace_root(params, git_root) do
    value =
      params
      |> Map.get("workspace_root", Map.get(params, :workspace_root, ""))
      |> to_string()
      |> String.trim()

    root =
      if value == "" do
        git_root
        |> Path.dirname()
        |> Path.join("#{Path.basename(git_root)}-workspaces")
      else
        expand_path(value)
      end

    {:ok, root}
  end

  defp runtime_session_name(result) do
    base = slugify("#{result.project_name}-#{result.port}")
    "cognition-#{base}" |> String.slice(0, 80)
  end

  defp expand_path("~/"), do: System.user_home!()
  defp expand_path("~"), do: System.user_home!()
  defp expand_path(<<"~/", rest::binary>>), do: Path.join(System.user_home!(), rest)
  defp expand_path(path), do: Path.expand(path)

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "Unable to create #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Unable to write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp chmod_runner(path) do
    case File.chmod(path, 0o755) do
      :ok -> :ok
      {:error, reason} -> {:error, "Unable to mark #{path} executable: #{:file.format_error(reason)}"}
    end
  end

  defp yaml_string(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"#{&1}")
    |> then(&"\"#{&1}\"")
  end

  defp indent_block(value, spaces) do
    indent = String.duplicate(" ", spaces)

    value
    |> String.split("\n")
    |> Enum.map_join("\n", &(indent <> &1))
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  defp project_name_from_slug(slug_id, git_root) do
    git_root
    |> Path.basename()
    |> String.trim()
    |> case do
      "" -> String.replace(slug_id, "-", " ")
      name -> name
    end
  end

  defp format_linear_error(reason) when is_binary(reason), do: reason
  defp format_linear_error(reason), do: inspect(reason, limit: 20)
end
