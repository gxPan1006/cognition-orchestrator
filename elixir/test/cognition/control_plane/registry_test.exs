defmodule Cognition.ControlPlane.RegistryTest do
  use ExUnit.Case, async: false

  alias Cognition.ControlPlane.Registry

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "cognition-registry-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    %{path: tmp}
  end

  defp start_registry(path) do
    name = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    {:ok, pid} = Registry.start_link(name: name, persistence_path: path)
    %{pid: pid, name: name}
  end

  defp sample_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "demo",
        project_path: "/tmp/cognition-demo",
        workflow_path: "/tmp/cognition-demo/.cognition/WORKFLOW.md",
        runner_path: "/tmp/cognition-demo/.cognition/run-cognition.sh",
        tmux_session: "cognition-demo-4010",
        port: 4010,
        coding_tool: "claude",
        workspace_root: "/tmp/cognition-demo-workspaces"
      },
      overrides
    )
  end

  test "register adds an entry, persists to disk, broadcasts, and is idempotent", %{path: path} do
    %{name: name} = start_registry(path)

    :ok = Phoenix.PubSub.subscribe(Cognition.PubSub, "control_plane:registry")

    assert {:ok, entry} = Registry.register(name, sample_attrs())
    assert entry.name == "demo"
    assert entry.port == 4010
    assert entry.id == "demo-4010"
    assert entry.status == :unknown

    assert_receive {:project_registered, ^entry}

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["version"] == 1
    assert [persisted] = decoded["projects"]
    assert persisted["name"] == "demo"
    assert persisted["port"] == 4010
    refute Map.has_key?(persisted, "status")

    # Same id, different tmux_session → update existing entry, not duplicate
    assert {:ok, updated} = Registry.register(name, sample_attrs(%{tmux_session: "cognition-demo-renamed"}))
    assert updated.id == entry.id
    assert updated.tmux_session == "cognition-demo-renamed"
    assert length(Registry.list(name)) == 1
  end

  test "register validates required fields", %{path: path} do
    %{name: name} = start_registry(path)

    assert {:error, {:missing_field, "name"}} =
             Registry.register(name, Map.delete(sample_attrs(), :name))

    assert {:error, {:invalid_field, "port"}} =
             Registry.register(name, %{sample_attrs() | port: "not-a-port"})
  end

  test "unregister removes entry, persists, and broadcasts", %{path: path} do
    %{name: name} = start_registry(path)
    :ok = Phoenix.PubSub.subscribe(Cognition.PubSub, "control_plane:registry")

    assert {:ok, entry} = Registry.register(name, sample_attrs())
    assert_receive {:project_registered, ^entry}

    entry_id = entry.id
    :ok = Registry.unregister(name, entry_id)
    assert_receive {:project_unregistered, ^entry_id}
    assert Registry.list(name) == []

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["projects"] == []
  end

  test "update_runtime_state mutates in-memory only and broadcasts", %{path: path} do
    %{name: name} = start_registry(path)
    :ok = Phoenix.PubSub.subscribe(Cognition.PubSub, "control_plane:registry")

    {:ok, entry} = Registry.register(name, sample_attrs())
    assert_receive {:project_registered, _}

    now = DateTime.utc_now()

    :ok =
      Registry.update_runtime_state(name, entry.id, %{
        status: :running,
        last_probe_at: now,
        last_state: %{"running" => []},
        last_error: nil
      })

    assert_receive {:project_runtime_changed, updated}
    assert updated.status == :running
    assert updated.last_state == %{"running" => []}

    # JSON on disk does NOT carry runtime fields
    decoded = path |> File.read!() |> Jason.decode!()
    [persisted] = decoded["projects"]
    refute Map.has_key?(persisted, "status")
    refute Map.has_key?(persisted, "last_state")
  end

  test "loads persisted entries from disk on start", %{path: path} do
    payload = %{
      "version" => 1,
      "projects" => [
        %{
          "id" => "loaded-4011",
          "name" => "loaded",
          "project_path" => "/tmp/loaded",
          "workflow_path" => "/tmp/loaded/.cognition/WORKFLOW.md",
          "runner_path" => "/tmp/loaded/.cognition/run-cognition.sh",
          "tmux_session" => "cognition-loaded-4011",
          "port" => 4011,
          "coding_tool" => "codex",
          "workspace_root" => "/tmp/loaded-workspaces",
          "created_at" => "2026-04-01T00:00:00Z"
        }
      ]
    }

    File.write!(path, Jason.encode_to_iodata!(payload))

    %{name: name} = start_registry(path)

    [entry] = Registry.list(name)
    assert entry.id == "loaded-4011"
    assert entry.name == "loaded"
    assert entry.coding_tool == "codex"
    assert entry.status == :unknown
    assert %DateTime{} = entry.created_at
  end

  test "skips malformed persisted entries", %{path: path} do
    payload = %{
      "version" => 1,
      "projects" => [
        %{"name" => "incomplete"},
        %{
          "id" => "ok-4012",
          "name" => "ok",
          "project_path" => "/tmp/ok",
          "workflow_path" => "/tmp/ok/.cognition/WORKFLOW.md",
          "runner_path" => "/tmp/ok/.cognition/run-cognition.sh",
          "tmux_session" => "cognition-ok-4012",
          "port" => 4012,
          "coding_tool" => "claude",
          "workspace_root" => "/tmp/ok-workspaces"
        }
      ]
    }

    File.write!(path, Jason.encode_to_iodata!(payload))

    %{name: name} = start_registry(path)

    [entry] = Registry.list(name)
    assert entry.id == "ok-4012"
  end
end
