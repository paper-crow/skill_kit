defmodule SkillKit.Registry do
  @moduledoc """
  A GenServer+ETS hybrid registry for storing and retrieving `%SkillKit.Skill{}` structs.

  ## GenServer+ETS Hybrid Pattern

  Write operations (register, unregister) are serialized through the GenServer,
  ensuring consistency and preventing concurrent write conflicts. Read operations
  (get_skill, list_skills) bypass the GenServer entirely and read directly from
  the ETS table using the table reference stored in the caller's process.

  This pattern avoids a common GenServer bottleneck: with many concurrent LLM
  calls all performing skill lookups, routing every read through a single process
  would create a serialization point. Direct ETS reads scale to the number of
  available schedulers.

  ## ETS Table Design

  The ETS table uses `:set` type (unique keys), `:protected` visibility (only
  the owning GenServer can write), and `read_concurrency: true` for optimized
  concurrent reads. The table is **not** a named table — it is referenced by
  its ETS table reference, stored in GenServer state. This enables multiple
  isolated registry instances in the same node (critical for test isolation).

  ## Boot-time Loading

  When starting the registry via a supervision tree, you can pass `backends`
  to automatically load skills at boot time:

  - `:backends` — list of `{backend_module, backend_config}` tuples. Each
    backend module must implement `load_skills/1`, returning `{:ok, [%Skill{}]}`
    or `{:error, reason}`. Backends are iterated in order; first-registered-wins
    semantics apply when multiple backends provide skills with the same name.
    Backend failures are logged as warnings; the registry still starts successfully.

  Boot loading happens in `handle_continue/2`, which runs before any external
  calls can reach the GenServer. This means skills are available immediately
  after `start_link/1` returns — no race conditions.

  ## Test Isolation

  Each test can spin up its own registry instance with a unique name:

      setup do
        name = :"registry_\#{:erlang.unique_integer([:positive])}"
        registry = start_supervised!({SkillKit.Registry, name: name})
        %{registry: registry}
      end

  ## Namespace Validation

  Skill names must follow the format `"namespace:skill_name"`, where:
  - Exactly one colon separates the namespace from the skill name
  - Both segments match `~r/^[a-z][a-z0-9_-]*$/`
  - Multi-level nesting (`"a:b:c"`) is rejected
  - Missing colon, empty segments, and uppercase are rejected

  ## Usage

      {:ok, _pid} = SkillKit.Registry.start_link(name: MyApp.SkillRegistry)

      skill = %SkillKit.Skill{name: "files:read", namespace: "files"}
      :ok = SkillKit.Registry.register(MyApp.SkillRegistry, skill)

      {:ok, skill} = SkillKit.Registry.get_skill(MyApp.SkillRegistry, "files:read")
      :ok = SkillKit.Registry.unregister(MyApp.SkillRegistry, "files:read")
  """

  use GenServer

  require Logger

  alias SkillKit.Skill

  # Regex for valid namespace/skill name segments
  @segment_regex ~r/^[a-z][a-z0-9_-]*$/

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a SkillKit.Registry process linked to the current process.

  ## Options

  - `:name` — the name to register the GenServer under. Defaults to `__MODULE__`
    (`SkillKit.Registry`). Pass a unique atom for test isolation.
  - `:backends` — list of `{backend_module, backend_config}` tuples for boot-time
    skill loading. Defaults to `[]` (no skills loaded at boot).

  ## Examples

      iex> {:ok, _pid} = SkillKit.Registry.start_link([])
      iex> {:ok, _pid} = SkillKit.Registry.start_link(name: MyApp.Registry)
      iex> {:ok, _pid} = SkillKit.Registry.start_link(name: MyApp.Registry, backends: [{SkillKit.Backend.Filesystem, dirs: ["/path/to/skills"]}])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the child spec for embedding SkillKit.Registry in a supervision tree.

  ## Options

  Accepts the same options as `start_link/1`.
  """
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Registers a skill in the registry.

  The skill's `:name` field must follow the `"namespace:skill_name"` format.
  If a skill with the same name is already registered, it is overwritten
  (supporting Phase 2 hot-reload semantics).

  Returns `:ok` on success, or `{:error, :invalid_namespace}` if the name
  does not pass validation.

  ## Examples

      iex> skill = %SkillKit.Skill{name: "files:read", namespace: "files"}
      iex> SkillKit.Registry.register(skill)
      :ok

      iex> bad = %SkillKit.Skill{name: "no-colon", namespace: ""}
      iex> SkillKit.Registry.register(bad)
      {:error, :invalid_namespace}
  """
  @spec register(GenServer.server(), Skill.t()) :: :ok | {:error, :invalid_namespace}
  def register(server \\ __MODULE__, %Skill{} = skill) do
    GenServer.call(server, {:register, skill})
  end

  @doc """
  Removes a skill from the registry by name.

  This operation is idempotent — it returns `:ok` whether or not the skill
  was registered. Callers do not need to check existence before unregistering.

  ## Examples

      iex> SkillKit.Registry.unregister("files:read")
      :ok

      iex> SkillKit.Registry.unregister("nonexistent:skill")
      :ok
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc """
  Retrieves a skill by its fully-qualified name.

  Reads directly from ETS, bypassing the GenServer, for concurrent read
  scalability.

  Returns `{:ok, skill}` if found, or `{:error, :not_found}` otherwise.

  ## Examples

      iex> SkillKit.Registry.get_skill("files:read")
      {:ok, %SkillKit.Skill{name: "files:read", namespace: "files"}}

      iex> SkillKit.Registry.get_skill("unknown:skill")
      {:error, :not_found}
  """
  @spec get_skill(GenServer.server(), String.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_skill(server \\ __MODULE__, name) when is_binary(name) do
    table = get_table(server)

    case :ets.lookup(table, name) do
      [{^name, skill}] -> {:ok, skill}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all registered skills, with an optional namespace filter.

  Reads directly from ETS, bypassing the GenServer, for concurrent read
  scalability.

  ## Options

  - `:namespace` — when provided, returns only skills whose `:namespace` field
    exactly matches the given string. This is an exact match, not a prefix or
    wildcard match (wildcard matching is Phase 3 scope authorization).

  ## Examples

      iex> SkillKit.Registry.list_skills()
      [%SkillKit.Skill{name: "files:read", namespace: "files"}]

      iex> SkillKit.Registry.list_skills(namespace: "files")
      [%SkillKit.Skill{name: "files:read", namespace: "files"}]

      iex> SkillKit.Registry.list_skills(namespace: "unknown")
      []
  """
  @spec list_skills(GenServer.server(), keyword()) :: [Skill.t()]
  def list_skills(server \\ __MODULE__, opts \\ []) do
    table = get_table(server)
    all_skills = :ets.tab2list(table) |> Enum.map(fn {_name, skill} -> skill end)

    case Keyword.fetch(opts, :namespace) do
      {:ok, namespace} -> Enum.filter(all_skills, &(&1.namespace == namespace))
      :error -> all_skills
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    table = :ets.new(:skill_kit_registry, [:set, :protected, {:read_concurrency, true}])
    {:ok, %{table: table, opts: opts}, {:continue, :load_skills}}
  end

  @impl true
  def handle_continue(:load_skills, state) do
    backends = Keyword.get(state.opts, :backends, [])

    Enum.each(backends, fn {backend_mod, backend_config} ->
      case backend_mod.load_skills(backend_config) do
        {:ok, skills} ->
          Enum.each(skills, fn skill ->
            # First-registered-wins: only insert if not already present
            if :ets.lookup(state.table, skill.name) == [] do
              :ets.insert(state.table, {skill.name, skill})
            end
          end)

        {:error, reason} ->
          Logger.warning("SkillKit: backend #{inspect(backend_mod)} failed: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
  end

  @impl true
  def handle_call({:register, skill}, _from, state) do
    case validate_namespace(skill.name) do
      {:ok, _} ->
        :ets.insert(state.table, {skill.name, skill})
        {:reply, :ok, state}

      {:error, :invalid_namespace} ->
        {:reply, {:error, :invalid_namespace}, state}
    end
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(state.table, name)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Retrieves the ETS table reference from the GenServer state.
  # Called once by read functions to get the table ref, then subsequent
  # reads happen directly against ETS without any GenServer involvement.
  defp get_table(server) do
    GenServer.call(server, :get_table)
  end

  # Validates that a skill name follows the "namespace:skill_name" format.
  # Delegates to parse_namespaced_name/1 for the shared parsing logic.
  defp validate_namespace(name) when is_binary(name) do
    case parse_namespaced_name(name) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_namespace}
    end
  end

  defp validate_namespace(_), do: {:error, :invalid_namespace}

  # Parses and validates a "namespace:skill_name" string.
  #
  # Shared parsing logic used by both validate_namespace/1 (runtime register path)
  # and validate_skill_name/1 (boot code-skill path).
  #
  # Rules:
  #   - Exactly one colon, producing exactly two segments
  #   - Both segments match ~r/^[a-z][a-z0-9_-]*$/ (lowercase start, alphanumeric + hyphens/underscores)
  #   - Rejects: no colon, multi-level ("a:b:c"), empty segments (":name", "ns:"), uppercase
  #
  # Returns {:ok, {namespace, skill_name}} or :error
  @spec parse_namespaced_name(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  defp parse_namespaced_name(name) when is_binary(name) do
    case String.split(name, ":", parts: 3) do
      [namespace, skill_name] ->
        if valid_segment?(namespace) and valid_segment?(skill_name) do
          {:ok, {namespace, skill_name}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp valid_segment?(segment) do
    String.match?(segment, @segment_regex)
  end
end
