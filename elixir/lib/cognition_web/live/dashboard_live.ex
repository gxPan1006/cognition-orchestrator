defmodule CognitionWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cognition.
  """

  use Phoenix.LiveView, layout: {CognitionWeb.Layouts, :app}

  alias Cognition.{ClaudeSessions, CodexSessions}
  alias Cognition.ControlPlane.{Prober, ProjectRuntime, Registry}
  alias Cognition.ProjectSetup
  alias CognitionWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    mode = Cognition.Application.runtime_mode()
    socket = assign(socket, :runtime_mode, mode)
    socket = mount_assigns(socket, mode)

    if connected?(socket) do
      subscribe_for_mode(mode)
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  defp mount_assigns(socket, :control_plane) do
    socket
    |> assign(:registry_entries, load_registry_entries())
    |> assign(:now, DateTime.utc_now())
    |> assign(:project_setup_form, project_setup_form())
    |> assign(:project_setup_result, nil)
    |> assign(:project_setup_error, nil)
    |> assign(:project_setup_pending, nil)
    |> assign(:project_picker_error, nil)
    |> assign(:project_action_error, nil)
    |> assign_project_browser(default_browser_path())
  end

  defp mount_assigns(socket, _project) do
    tool = current_coding_tool()

    socket
    |> assign(:payload, load_payload())
    |> assign(:now, DateTime.utc_now())
    |> assign(:coding_tool_kind, tool)
    |> assign(:agent_sessions, load_agent_sessions(tool))
  end

  defp subscribe_for_mode(:control_plane), do: :ok = Registry.subscribe()
  defp subscribe_for_mode(_project), do: :ok = ObservabilityPubSub.subscribe()

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:observability_updated, socket) do
    tool = current_coding_tool()

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())
     |> assign(:coding_tool_kind, tool)
     |> assign(:agent_sessions, load_agent_sessions(tool))}
  end

  def handle_info({:project_registered, _entry}, socket), do: refresh_registry(socket)
  def handle_info({:project_unregistered, _id}, socket), do: refresh_registry(socket)
  def handle_info({:project_runtime_changed, _entry}, socket), do: refresh_registry(socket)
  def handle_info(_other, socket), do: {:noreply, socket}

  defp refresh_registry(socket) do
    {:noreply, assign(socket, :registry_entries, load_registry_entries())}
  end

  @impl true
  def handle_event("prepare_project", %{"project_setup" => params}, socket) do
    if socket.assigns.project_setup_pending do
      {:noreply, socket}
    else
      form = project_setup_form(params)
      pending = pending_label(params)

      socket =
        socket
        |> assign(:project_setup_form, form)
        |> assign(:project_setup_result, nil)
        |> assign(:project_setup_error, nil)
        |> assign(:project_setup_pending, pending)
        |> Phoenix.LiveView.start_async(:prepare_project, fn -> ProjectSetup.prepare(params) end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate_project_setup", %{"project_setup" => params}, socket) do
    {:noreply, assign(socket, :project_setup_form, project_setup_form(params))}
  end

  @impl true
  def handle_event("browse_project_path", %{"path" => path}, socket) do
    {:noreply, assign_project_browser(socket, path)}
  end

  @impl true
  def handle_event("select_project_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, :project_setup_form, Map.put(socket.assigns.project_setup_form, :project_path, path))}
  end

  @impl true
  def handle_event("choose_project_folder", _params, socket) do
    start_path = selected_or_browser_path(socket)

    case pick_project_folder(start_path) do
      {:ok, path} ->
        {:noreply,
         socket
         |> assign(:project_setup_form, Map.put(socket.assigns.project_setup_form, :project_path, path))
         |> assign(:project_picker_error, nil)
         |> assign_project_browser(path)}

      {:error, :cancelled} ->
        {:noreply, assign(socket, :project_picker_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :project_picker_error, message)}
    end
  end

  @impl true
  def handle_event("start_project_runtime", %{"id" => id}, socket) do
    {:noreply, dispatch_runtime_action(socket, id, :start)}
  end

  @impl true
  def handle_event("stop_project_runtime", %{"id" => id}, socket) do
    {:noreply, dispatch_runtime_action(socket, id, :stop)}
  end

  @impl true
  def handle_event("restart_project_runtime", %{"id" => id}, socket) do
    {:noreply, dispatch_runtime_action(socket, id, :restart)}
  end

  @impl true
  def handle_event("forget_project_runtime", %{"id" => id}, socket) do
    Registry.unregister(id)
    {:noreply, assign(socket, :project_action_error, nil)}
  end

  @impl true
  def handle_async(:prepare_project, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> assign(:project_setup_pending, nil)
     |> assign(:project_setup_result, result)
     |> assign(:project_setup_error, nil)}
  end

  def handle_async(:prepare_project, {:ok, {:error, message}}, socket) do
    {:noreply,
     socket
     |> assign(:project_setup_pending, nil)
     |> assign(:project_setup_result, nil)
     |> assign(:project_setup_error, message)}
  end

  def handle_async(:prepare_project, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:project_setup_pending, nil)
     |> assign(:project_setup_result, nil)
     |> assign(:project_setup_error, "Preparation crashed: #{inspect(reason, limit: 5)}")}
  end

  defp pending_label(params) when is_map(params) do
    path =
      params
      |> Map.get("project_path", Map.get(params, :project_path, ""))
      |> to_string()
      |> String.trim()

    if path == "", do: "your project", else: Path.basename(path)
  end

  defp dispatch_runtime_action(socket, id, action) do
    case Registry.fetch(id) do
      {:ok, entry} ->
        perform_runtime_action(entry, action)
        assign(socket, :project_action_error, nil)

      :error ->
        assign(socket, :project_action_error, "Project #{id} is no longer registered.")
    end
  end

  defp perform_runtime_action(entry, :start) do
    Registry.update_runtime_state(entry.id, %{status: :starting, last_error: nil})
    spawn_runtime_task(entry, fn -> ProjectRuntime.start(entry) end)
  end

  defp perform_runtime_action(entry, :stop) do
    Registry.update_runtime_state(entry.id, %{status: :stopped, last_error: nil})
    spawn_runtime_task(entry, fn -> ProjectRuntime.stop(entry) end)
  end

  defp perform_runtime_action(entry, :restart) do
    Registry.update_runtime_state(entry.id, %{status: :starting, last_error: nil})
    spawn_runtime_task(entry, fn -> ProjectRuntime.restart(entry) end)
  end

  defp spawn_runtime_task(entry, fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(Cognition.TaskSupervisor, fn ->
      result = fun.()
      handle_runtime_task_result(entry.id, result)
    end)
  end

  defp handle_runtime_task_result(_id, :ok) do
    Prober.probe_now()
  end

  defp handle_runtime_task_result(_id, {:ok, _runtime}) do
    Prober.probe_now()
  end

  defp handle_runtime_task_result(id, {:error, reason}) do
    Registry.update_runtime_state(id, %{status: :error, last_error: format_runtime_reason(reason)})
  end

  defp format_runtime_reason(reason) when is_binary(reason), do: reason

  @impl true
  def render(%{runtime_mode: :control_plane} = assigns), do: render_control_plane(assigns)
  def render(assigns), do: render_project(assigns)

  defp render_project(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Cognition Runtime
            </p>
            <h1 class="hero-title">
              Agent Activity
            </h1>
            <p class="hero-copy">
              Live status, token usage, and retries for this project's Symphony loop.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total agent runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Agent update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= agent_sessions_title(@coding_tool_kind) %></h2>
              <p class="section-copy">
                <%= agent_sessions_copy(@coding_tool_kind) %>
              </p>
            </div>
          </div>

          <%= if @agent_sessions == [] do %>
            <p class="empty-state"><%= agent_sessions_empty(@coding_tool_kind) %></p>
          <% else %>
            <div class="claude-session-groups">
              <div :for={group <- @agent_sessions} class="claude-session-group">
                <header class="claude-session-group-header">
                  <span class="issue-id"><%= group.issue_identifier %></span>
                  <code class="claude-session-workspace"><%= group.workspace %></code>
                </header>

                <ul class="claude-session-list">
                  <li :for={session <- group.sessions} class="claude-session-row">
                    <div class="claude-session-meta">
                      <code class="claude-session-id" title={session.id}><%= short_session_id(session.id) %></code>
                      <span class="muted claude-session-time mono"><%= format_iso_seconds(session.modified_at) %></span>
                      <span class="muted claude-session-stats numeric">
                        <%= session.event_count %> events · <%= format_byte_size(session.byte_size) %>
                      </span>
                    </div>
                    <div class="claude-session-actions">
                      <button
                        type="button"
                        class="subtle-button"
                        data-label="Copy resume"
                        data-copy={agent_resume_command(@coding_tool_kind, group.workspace, session.id)}
                        onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                      >
                        Copy resume
                      </button>
                      <button
                        type="button"
                        class="subtle-button"
                        data-label="Copy ID"
                        data-copy={session.id}
                        onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                      >
                        Copy ID
                      </button>
                    </div>
                  </li>
                </ul>
              </div>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp short_session_id(id) when is_binary(id) and byte_size(id) >= 8 do
    binary_part(id, 0, 8) <> "…"
  end

  defp short_session_id(id), do: id

  defp render_control_plane(assigns) do
    counts = runtime_status_counts(assigns.registry_entries)
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Cognition Control Plane</p>
            <h1 class="hero-title">Project Runtimes</h1>
            <p class="hero-copy">
              Manage Symphony processes for every tracked project. Each row below is a dedicated Cognition runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-pill status-pill-running">
              <span class="status-pill-dot"></span>
              <%= @counts.running %> running
            </span>
            <span class="status-pill status-pill-stopped">
              <span class="status-pill-dot"></span>
              <%= @counts.stopped %> stopped
            </span>
            <span class="status-pill status-pill-total">
              <%= @counts.total %> total
            </span>
          </div>
        </div>
      </header>

      <%= if @project_action_error do %>
        <section class="error-card">
          <h2 class="error-title">Action failed</h2>
          <p class="error-copy"><%= @project_action_error %></p>
        </section>
      <% end %>

      <section class="section-card runtime-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Runtimes</h2>
            <p class="section-copy">Each runtime is an independent Cognition BEAM process bound to its own port.</p>
          </div>
        </div>

        <%= if @registry_entries == [] do %>
          <p class="empty-state">No projects registered yet. Prepare one below to launch its first runtime.</p>
        <% else %>
          <ul class="runtime-list">
            <li :for={entry <- @registry_entries} class={"runtime-row runtime-row-#{entry.status}"}>
              <div class="runtime-row-primary">
                <div class="runtime-identity">
                  <span class="runtime-name"><%= entry.name %></span>
                  <code class="runtime-path"><%= entry.project_path %></code>
                </div>
                <div class="runtime-meta">
                  <span class={"runtime-status runtime-status-#{entry.status}"}>
                    <span class="runtime-status-dot"></span>
                    <%= runtime_status_label(entry.status) %>
                  </span>
                  <span class="runtime-port">
                    <%= if entry.status == :running do %>
                      <a href={"http://127.0.0.1:#{entry.port}/"} target="_blank" rel="noopener" class="runtime-port-link">
                        port <%= entry.port %> ↗
                      </a>
                    <% else %>
                      port <%= entry.port %>
                    <% end %>
                  </span>
                </div>
              </div>

              <div class="runtime-row-detail">
                <div class="runtime-stat">
                  <span class="runtime-stat-label">Tool</span>
                  <span class="runtime-stat-value"><%= entry.coding_tool %></span>
                </div>
                <div class="runtime-stat">
                  <span class="runtime-stat-label">Active issue</span>
                  <span class="runtime-stat-value"><%= runtime_active_issue(entry) %></span>
                </div>
                <div class="runtime-stat">
                  <span class="runtime-stat-label">Tokens</span>
                  <span class="runtime-stat-value numeric"><%= runtime_token_summary(entry) %></span>
                </div>
                <div class="runtime-stat">
                  <span class="runtime-stat-label">Last seen</span>
                  <span class="runtime-stat-value mono"><%= runtime_last_seen(entry) %></span>
                </div>
              </div>

              <%= if entry.last_error do %>
                <p class="runtime-error"><%= entry.last_error %></p>
              <% end %>

              <div class="runtime-actions">
                <%= if entry.linear_url do %>
                  <a class="runtime-action secondary" href={linear_issues_url(entry.linear_url)} target="_blank" rel="noopener">Linear ↗</a>
                <% end %>

                <%= if entry.status == :running do %>
                  <a class="runtime-action runtime-action-primary" href={"http://127.0.0.1:#{entry.port}/"} target="_blank" rel="noopener">Open ↗</a>
                  <button class="runtime-action secondary" phx-click="restart_project_runtime" phx-value-id={entry.id}>Restart</button>
                  <button class="runtime-action secondary" phx-click="stop_project_runtime" phx-value-id={entry.id}>Stop</button>
                <% end %>

                <%= if entry.status == :starting do %>
                  <span class="runtime-action runtime-action-pending">Starting…</span>
                  <button class="runtime-action secondary" phx-click="stop_project_runtime" phx-value-id={entry.id}>Cancel</button>
                <% end %>

                <%= if entry.status in [:stopped, :unknown] do %>
                  <button class="runtime-action runtime-action-primary" phx-click="start_project_runtime" phx-value-id={entry.id}>Start</button>
                  <button class="runtime-action subtle" phx-click="forget_project_runtime" phx-value-id={entry.id} data-confirm="Forget this project from the registry?">Forget</button>
                <% end %>

                <%= if entry.status == :error do %>
                  <button class="runtime-action runtime-action-primary" phx-click="restart_project_runtime" phx-value-id={entry.id}>Retry</button>
                  <button class="runtime-action subtle" phx-click="forget_project_runtime" phx-value-id={entry.id} data-confirm="Forget this project from the registry?">Forget</button>
                <% end %>
              </div>
            </li>
          </ul>
        <% end %>
      </section>

      <section class="section-card setup-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Add a project</h2>
            <p class="section-copy">Pick a local Git project, prepare its Cognition files, then launch its runtime.</p>
          </div>
        </div>

        <div class="onboarding-layout">
          <form class="setup-form" phx-change="validate_project_setup" phx-submit="prepare_project">
            <label class="form-field form-field-wide">
              <span>Project folder</span>
              <div class="path-picker">
                <input
                  type="text"
                  name="project_setup[project_path]"
                  value={@project_setup_form.project_path}
                  placeholder="/Users/you/code/project"
                  autocomplete="off"
                  required
                />
                <button
                  type="button"
                  class="secondary path-picker-button"
                  phx-click="choose_project_folder"
                  phx-disable-with="Opening..."
                >
                  Choose...
                </button>
              </div>
            </label>

            <%= if @project_picker_error do %>
              <p class="setup-message setup-message-error"><%= @project_picker_error %></p>
            <% end %>

            <div class="setup-form-grid">
              <label class="form-field">
                <span>Linear project slug</span>
                <input
                  type="text"
                  name="project_setup[project_slug]"
                  value={@project_setup_form.project_slug}
                  placeholder="defaults to folder name"
                  autocomplete="off"
                />
              </label>

              <label class="form-field">
                <span>Coding tool</span>
                <select name="project_setup[coding_tool]">
                  <option value="codex" selected={@project_setup_form.coding_tool == "codex"}>Codex</option>
                  <option value="claude" selected={@project_setup_form.coding_tool == "claude"}>Claude Code</option>
                </select>
              </label>

              <label class="form-field">
                <span>Clone source</span>
                <select name="project_setup[clone_source]">
                  <option value="auto" selected={@project_setup_form.clone_source == "auto"}>Auto</option>
                  <option value="origin" selected={@project_setup_form.clone_source == "origin"}>Git origin</option>
                  <option value="local" selected={@project_setup_form.clone_source == "local"}>Local folder</option>
                </select>
              </label>
            </div>

            <label class="form-field form-field-wide">
              <span>Workspace root</span>
              <input
                type="text"
                name="project_setup[workspace_root]"
                value={@project_setup_form.workspace_root}
                placeholder="defaults next to the selected project"
                autocomplete="off"
              />
            </label>

            <div class="form-actions">
              <button
                type="submit"
                disabled={@project_setup_pending != nil}
                phx-disable-with="Preparing…"
              >
                <%= if @project_setup_pending, do: "Preparing…", else: "Prepare and start" %>
              </button>
            </div>
          </form>

          <div class="folder-browser">
            <div class="folder-browser-header">
              <div>
                <h3>Directory browser</h3>
                <code><%= @project_browser_path %></code>
              </div>
              <div class="folder-browser-actions">
                <button
                  type="button"
                  class="secondary"
                  phx-click="browse_project_path"
                  phx-value-path={parent_path(@project_browser_path)}
                >
                  Up
                </button>
                <button
                  type="button"
                  class="secondary"
                  phx-click="select_project_path"
                  phx-value-path={@project_browser_path}
                >
                  Use current
                </button>
              </div>
            </div>

            <%= if @project_browser_error do %>
              <p class="setup-message setup-message-error"><%= @project_browser_error %></p>
            <% end %>

            <div class="folder-list">
              <div :for={entry <- @project_browser_entries} class="folder-row">
                <button
                  type="button"
                  class="folder-name-button"
                  phx-click="browse_project_path"
                  phx-value-path={entry.path}
                >
                  <span><%= entry.name %></span>
                  <code><%= entry.path %></code>
                </button>
                <button
                  type="button"
                  class="subtle-button"
                  phx-click="select_project_path"
                  phx-value-path={entry.path}
                >
                  Use
                </button>
              </div>
            </div>
          </div>
        </div>

        <%= if @project_setup_pending do %>
          <div class="setup-pending" role="status" aria-live="polite">
            <span class="setup-pending-spinner" aria-hidden="true"></span>
            <div class="setup-pending-copy">
              <strong>Preparing <%= @project_setup_pending %>…</strong>
              <span>Initialising Git if needed, syncing with Linear, picking a free port, writing <code>.cognition/</code>, then launching the tmux runtime. This usually takes a few seconds.</span>
            </div>
          </div>
        <% end %>

        <%= if @project_setup_error do %>
          <p class="setup-message setup-message-error"><%= @project_setup_error %></p>
        <% end %>

        <%= if @project_setup_result do %>
          <div class="setup-result">
            <div class="setup-result-grid">
              <span>
                <strong>Workflow</strong>
                <code><%= @project_setup_result.workflow_path %></code>
              </span>
              <span>
                <strong>Workspaces</strong>
                <code><%= @project_setup_result.workspace_root %></code>
              </span>
              <span>
                <strong>Clone source</strong>
                <code><%= @project_setup_result.clone_source %></code>
              </span>
              <span>
                <strong>Tool</strong>
                <code><%= @project_setup_result.coding_tool %></code>
              </span>
              <span>
                <strong>Linear project</strong>
                <code><%= linear_project_status(@project_setup_result) %></code>
              </span>
              <span>
                <strong>Runtime</strong>
                <code><%= @project_setup_result.runtime_url || "launched" %></code>
              </span>
              <span>
                <strong>Session</strong>
                <code><%= @project_setup_result.runtime_session || "n/a" %></code>
              </span>
            </div>

            <%= if @project_setup_result.warnings != [] do %>
              <ul class="setup-warnings">
                <li :for={warning <- @project_setup_result.warnings}><%= warning %></li>
              </ul>
            <% end %>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp load_registry_entries do
    case Process.whereis(Registry) do
      pid when is_pid(pid) -> Registry.list()
      _ -> []
    end
  end

  defp runtime_status_counts(entries) do
    Enum.reduce(entries, %{running: 0, stopped: 0, total: 0}, fn entry, acc ->
      acc = Map.update!(acc, :total, &(&1 + 1))

      case entry.status do
        :running -> Map.update!(acc, :running, &(&1 + 1))
        _ -> Map.update!(acc, :stopped, &(&1 + 1))
      end
    end)
  end

  defp runtime_status_label(:running), do: "Running"
  defp runtime_status_label(:starting), do: "Starting"
  defp runtime_status_label(:stopped), do: "Stopped"
  defp runtime_status_label(:error), do: "Error"
  defp runtime_status_label(_), do: "Unknown"

  defp runtime_active_issue(%{status: :running, last_state: %{"running" => running}}) when is_list(running) do
    case running do
      [%{"issue_identifier" => id} | _] -> id
      _ -> "—"
    end
  end

  defp runtime_active_issue(_entry), do: "—"

  defp runtime_token_summary(%{status: :running, last_state: %{"running" => [%{"tokens" => tokens} | _]}}) when is_map(tokens) do
    total = Map.get(tokens, "total_tokens") || 0
    format_int(total)
  end

  defp runtime_token_summary(_entry), do: "—"

  defp runtime_last_seen(%{last_probe_at: nil}), do: "—"

  defp runtime_last_seen(%{last_probe_at: %DateTime{} = dt}) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp runtime_last_seen(_entry), do: "—"

  defp linear_issues_url(url) when is_binary(url) do
    trimmed = String.trim_trailing(url, "/")
    if String.ends_with?(trimmed, "/issues"), do: trimmed, else: trimmed <> "/issues"
  end

  defp linear_issues_url(_), do: nil

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_agent_sessions(tool) do
    case safe_workspace_root() do
      nil ->
        []

      root ->
        case tool do
          "claude" -> ClaudeSessions.list(root)
          "codex" -> CodexSessions.list(root)
          _ -> []
        end
    end
  end

  defp safe_workspace_root do
    Cognition.Config.settings!().workspace.root
  rescue
    _ -> nil
  end

  defp current_coding_tool do
    Cognition.Config.settings!().coding_tool.kind |> to_string()
  rescue
    _ -> "claude"
  end

  defp agent_sessions_title("codex"), do: "Codex sessions on disk"
  defp agent_sessions_title(_), do: "Claude sessions on disk"

  defp agent_sessions_copy("codex") do
    "Local rollouts written by Codex for each workspace. Click Copy resume, paste in a terminal."
  end

  defp agent_sessions_copy(_) do
    "Local transcripts written by claude --print for each workspace. Click Copy resume, paste in a terminal."
  end

  defp agent_sessions_empty("codex") do
    "No Codex rollouts have been written for this project's workspaces yet."
  end

  defp agent_sessions_empty(_) do
    "No Claude sessions have been written for this project's workspaces yet."
  end

  defp agent_resume_command("codex", workspace, id), do: CodexSessions.resume_command(workspace, id)
  defp agent_resume_command(_tool, workspace, id), do: ClaudeSessions.resume_command(workspace, id)

  defp format_byte_size(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_byte_size(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_byte_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_byte_size(_), do: "—"

  defp format_iso_seconds(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_iso_seconds(_), do: "—"

  defp orchestrator do
    Endpoint.config(:orchestrator) || Cognition.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp linear_project_status(result) do
    status = if result.linear_project_created, do: "created", else: "existing"
    "#{status} · #{result.project_slug}"
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp project_setup_form(params \\ %{}) do
    %{
      project_path: project_setup_value(params, "project_path", ""),
      project_slug: project_setup_value(params, "project_slug", ""),
      coding_tool: project_setup_value(params, "coding_tool", "codex"),
      clone_source: project_setup_value(params, "clone_source", "auto"),
      workspace_root: project_setup_value(params, "workspace_root", "")
    }
  end

  defp project_setup_value(params, key, default) do
    params
    |> Map.get(key, Map.get(params, String.to_atom(key), default))
    |> to_string()
  end

  defp default_browser_path do
    code_path = Path.join(System.user_home!(), "code")
    if File.dir?(code_path), do: code_path, else: System.user_home!()
  end

  defp assign_project_browser(socket, path) do
    browser = load_project_browser(path)

    socket
    |> assign(:project_browser_path, browser.path)
    |> assign(:project_browser_entries, browser.entries)
    |> assign(:project_browser_error, browser.error)
  end

  defp load_project_browser(path) do
    expanded = path |> to_string() |> expand_home() |> Path.expand()

    cond do
      not File.exists?(expanded) ->
        %{path: expanded, entries: [], error: "Folder does not exist: #{expanded}"}

      not File.dir?(expanded) ->
        parent = Path.dirname(expanded)
        %{path: parent, entries: directory_entries(parent), error: "Selected path is not a folder: #{expanded}"}

      true ->
        %{path: expanded, entries: directory_entries(expanded), error: nil}
    end
  end

  defp directory_entries(path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.map(&%{name: &1, path: Path.join(path, &1)})
        |> Enum.filter(&File.dir?(&1.path))
        |> Enum.reject(&String.starts_with?(&1.name, "."))
        |> Enum.sort_by(&String.downcase(&1.name))
        |> Enum.take(200)

      {:error, _reason} ->
        []
    end
  end

  defp parent_path(path) do
    path
    |> to_string()
    |> Path.dirname()
  end

  defp expand_home("~/"), do: System.user_home!()
  defp expand_home("~"), do: System.user_home!()
  defp expand_home(<<"~/", rest::binary>>), do: Path.join(System.user_home!(), rest)
  defp expand_home(path), do: path

  defp selected_or_browser_path(socket) do
    selected = socket.assigns.project_setup_form.project_path

    if selected == "", do: socket.assigns.project_browser_path, else: selected
  end

  defp pick_project_folder(start_path) do
    picker = Application.get_env(:cognition, :project_folder_picker, &__MODULE__.macos_folder_picker/1)
    picker.(start_path)
  end

  @doc false
  @spec macos_folder_picker(String.t()) :: {:ok, String.t()} | {:error, String.t() | :cancelled}
  def macos_folder_picker(start_path) do
    default_path =
      start_path
      |> to_string()
      |> expand_home()
      |> Path.expand()
      |> default_picker_path()

    if System.find_executable("osascript") do
      run_macos_folder_picker(default_path)
    else
      {:error, "Native folder picker is unavailable; use the directory browser below."}
    end
  end

  defp default_picker_path(path) do
    cond do
      File.dir?(path) -> path
      File.dir?(Path.dirname(path)) -> Path.dirname(path)
      true -> default_browser_path()
    end
  end

  defp run_macos_folder_picker(default_path) do
    default_path = apple_script_string(default_path)

    args = [
      "-e",
      "try",
      "-e",
      "set defaultFolder to POSIX file \"#{default_path}\"",
      "-e",
      "set selectedFolder to choose folder with prompt \"Select project folder\" default location defaultFolder",
      "-e",
      "return POSIX path of selectedFolder",
      "-e",
      "on error number -128",
      "-e",
      "return \"__COGNITION_CANCELLED__\"",
      "-e",
      "end try"
    ]

    case System.cmd("osascript", args, stderr_to_stdout: true) do
      {message, 0} ->
        case String.trim(message) do
          "__COGNITION_CANCELLED__" -> {:error, :cancelled}
          path -> {:ok, String.trim_trailing(path, "/")}
        end

      {message, _status} ->
        {:error, String.trim(message)}
    end
  end

  defp apple_script_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
