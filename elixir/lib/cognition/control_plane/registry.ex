defmodule Cognition.ControlPlane.Registry do
  @moduledoc """
  Persisted list of Cognition project runtimes spawned from the control plane.

  Each entry stores enough information for the control plane to display, probe,
  and (re)launch a project's dedicated Cognition BEAM process without ever
  needing to consult the project's own `WORKFLOW.md`.
  """

  use GenServer

  require Logger

  alias Phoenix.PubSub

  @pubsub Cognition.PubSub
  @topic "control_plane:registry"
  @persistence_version 1

  @type status :: :unknown | :starting | :running | :stopped | :error
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          project_path: String.t(),
          workflow_path: String.t(),
          runner_path: String.t(),
          tmux_session: String.t(),
          port: pos_integer(),
          linear_url: String.t() | nil,
          coding_tool: String.t(),
          workspace_root: String.t(),
          created_at: DateTime.t(),
          status: status(),
          last_probe_at: DateTime.t() | nil,
          last_state: map() | nil,
          last_error: String.t() | nil
        }

  @persistent_keys ~w(id name project_path workflow_path runner_path tmux_session port linear_url coding_tool workspace_root created_at)a
  @required_string_fields ~w(name project_path workflow_path runner_path tmux_session coding_tool workspace_root)

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec list(GenServer.server()) :: [entry()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @spec fetch(GenServer.server(), String.t()) :: {:ok, entry()} | :error
  def fetch(server \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(server, {:fetch, id})
  end

  @doc """
  Insert or update an entry by `:id`. Persists the result to disk.
  """
  @spec register(GenServer.server(), map()) :: {:ok, entry()} | {:error, term()}
  def register(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:register, attrs})
  end

  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, id) when is_binary(id) do
    GenServer.call(server, {:unregister, id})
  end

  @doc """
  Update the live status fields of an entry. Does not touch persisted storage.
  """
  @spec update_runtime_state(GenServer.server(), String.t(), map()) :: :ok
  def update_runtime_state(server \\ __MODULE__, id, runtime_state)
      when is_binary(id) and is_map(runtime_state) do
    GenServer.cast(server, {:update_runtime_state, id, runtime_state})
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    PubSub.subscribe(@pubsub, @topic)
  end

  @spec persistence_path() :: Path.t()
  def persistence_path do
    Application.get_env(:cognition, :registry_persistence_path) ||
      default_persistence_path()
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :persistence_path, persistence_path())
    persistent = load_from_disk(path)
    entries = Enum.map(persistent, &hydrate_runtime_fields/1)

    {:ok, %{entries: entries, persistence_path: path}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call({:fetch, id}, _from, state) do
    case find_entry(state.entries, id) do
      nil -> {:reply, :error, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:register, attrs}, _from, state) do
    case build_entry(attrs, find_entry(state.entries, Map.get(attrs, :id))) do
      {:ok, entry} ->
        entries = upsert_entry(state.entries, entry)
        state = %{state | entries: entries}
        :ok = persist(state)
        broadcast({:project_registered, entry})
        {:reply, {:ok, entry}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, id}, _from, state) do
    {removed, remaining} = pop_entry(state.entries, id)
    state = %{state | entries: remaining}

    case removed do
      nil ->
        {:reply, :ok, state}

      _entry ->
        :ok = persist(state)
        broadcast({:project_unregistered, id})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:update_runtime_state, id, runtime_state}, state) do
    case find_entry(state.entries, id) do
      nil ->
        {:noreply, state}

      entry ->
        updated = Map.merge(entry, runtime_state)
        entries = upsert_entry(state.entries, updated)
        broadcast({:project_runtime_changed, updated})
        {:noreply, %{state | entries: entries}}
    end
  end

  # Helpers

  defp build_entry(attrs, existing) do
    attrs = stringify_atom_keys(attrs)

    with {:ok, fields} <- collect_required_strings(attrs),
         {:ok, port} <- required_port(attrs, "port") do
      {:ok, compose_entry(Map.put(fields, "port", port), attrs, existing)}
    end
  end

  defp collect_required_strings(attrs) do
    Enum.reduce_while(@required_string_fields, {:ok, %{}}, fn key, {:ok, acc} ->
      case required_string(attrs, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp compose_entry(fields, attrs, existing) do
    name = fields["name"]
    port = fields["port"]

    %{
      id: Map.get(attrs, "id") || existing_value(existing, :id) || derive_id(name, port),
      name: name,
      project_path: fields["project_path"],
      workflow_path: fields["workflow_path"],
      runner_path: fields["runner_path"],
      tmux_session: fields["tmux_session"],
      port: port,
      linear_url: Map.get(attrs, "linear_url"),
      coding_tool: fields["coding_tool"],
      workspace_root: fields["workspace_root"],
      created_at: existing_value(existing, :created_at) || DateTime.utc_now(),
      status: existing_value(existing, :status) || :unknown,
      last_probe_at: existing_value(existing, :last_probe_at),
      last_state: existing_value(existing, :last_state),
      last_error: existing_value(existing, :last_error)
    }
  end

  defp existing_value(nil, _key), do: nil
  defp existing_value(existing, key), do: Map.get(existing, key)

  defp stringify_atom_keys(map) do
    map
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
    |> Map.new()
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, {:missing_field, key}}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp required_port(map, key) do
    case Map.get(map, key) do
      port when is_integer(port) and port > 0 ->
        {:ok, port}

      port when is_binary(port) ->
        case Integer.parse(port) do
          {value, ""} when value > 0 -> {:ok, value}
          _ -> {:error, {:invalid_field, key}}
        end

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp derive_id(name, port) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "project"
        slug -> slug
      end

    "#{slug}-#{port}"
  end

  defp find_entry(_entries, nil), do: nil

  defp find_entry(entries, id) when is_binary(id) do
    Enum.find(entries, &(&1.id == id))
  end

  defp upsert_entry(entries, entry) do
    case Enum.find_index(entries, &(&1.id == entry.id)) do
      nil -> entries ++ [entry]
      idx -> List.replace_at(entries, idx, entry)
    end
  end

  defp pop_entry(entries, id) do
    case Enum.split_with(entries, &(&1.id == id)) do
      {[removed], remaining} -> {removed, remaining}
      {[], remaining} -> {nil, remaining}
    end
  end

  defp hydrate_runtime_fields(entry) do
    entry
    |> Map.put_new(:status, :unknown)
    |> Map.put_new(:last_probe_at, nil)
    |> Map.put_new(:last_state, nil)
    |> Map.put_new(:last_error, nil)
  end

  defp broadcast(message) do
    if Process.whereis(@pubsub), do: PubSub.broadcast(@pubsub, @topic, message)
    :ok
  end

  defp persist(state) do
    payload = %{
      "version" => @persistence_version,
      "projects" => Enum.map(state.entries, &serialise/1)
    }

    case File.mkdir_p(Path.dirname(state.persistence_path)) do
      :ok ->
        case File.write(state.persistence_path, Jason.encode_to_iodata!(payload, pretty: true)) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to persist control plane registry to #{state.persistence_path}: #{:file.format_error(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("Failed to ensure registry directory: #{:file.format_error(reason)}")
        :ok
    end
  end

  defp serialise(entry) do
    @persistent_keys
    |> Enum.map(fn key ->
      {Atom.to_string(key), serialise_value(Map.get(entry, key))}
    end)
    |> Map.new()
  end

  defp serialise_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialise_value(value), do: value

  defp load_from_disk(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         projects when is_list(projects) <- Map.get(decoded, "projects", []) do
      Enum.flat_map(projects, &load_entry/1)
    else
      _ -> []
    end
  end

  defp load_entry(raw) do
    case deserialise(raw) do
      {:ok, entry} ->
        [entry]

      {:error, reason} ->
        Logger.warning("Skipping malformed registry entry: #{inspect(reason)} payload=#{inspect(raw)}")
        []
    end
  end

  defp deserialise(map) when is_map(map) do
    with {:ok, name} <- required_string(map, "name"),
         {:ok, project_path} <- required_string(map, "project_path"),
         {:ok, workflow_path} <- required_string(map, "workflow_path"),
         {:ok, runner_path} <- required_string(map, "runner_path"),
         {:ok, tmux_session} <- required_string(map, "tmux_session"),
         {:ok, port} <- required_port(map, "port"),
         {:ok, coding_tool} <- required_string(map, "coding_tool"),
         {:ok, workspace_root} <- required_string(map, "workspace_root") do
      created_at = parse_datetime(Map.get(map, "created_at")) || DateTime.utc_now()
      id = Map.get(map, "id") || derive_id(name, port)

      {:ok,
       %{
         id: id,
         name: name,
         project_path: project_path,
         workflow_path: workflow_path,
         runner_path: runner_path,
         tmux_session: tmux_session,
         port: port,
         linear_url: Map.get(map, "linear_url"),
         coding_tool: coding_tool,
         workspace_root: workspace_root,
         created_at: created_at,
         status: :unknown,
         last_probe_at: nil,
         last_state: nil,
         last_error: nil
       }}
    end
  end

  defp deserialise(_other), do: {:error, :not_a_map}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp default_persistence_path do
    Path.join([System.user_home!(), ".cognition", "projects.json"])
  end
end
