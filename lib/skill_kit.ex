defmodule SkillKit do
  @moduledoc """
  SkillKit — programmatic, scope-based authorization for skills.

  SkillKit determines what skills and commands an agent, user, or runtime
  context can access. It provides a registry for discovering available skills
  and an authorization layer for controlling access to them.

  ## Architecture

  SkillKit is built in four phases:

  1. **Registry Foundation** (Phase 1) — This phase. A GenServer+ETS-backed
     skill registry that host applications supervise via `child_spec/1`.

  2. **Skill Loader** (Phase 2) — Loads skill definitions from YAML files on
     disk, including behaviour-based validation and hot-reload support.

  3. **Authorization Layer** (Phase 3) — Scope-based access control: grants,
     denials, wildcard matching, and context-based authorization decisions.

  4. **Adapters** (Phase 4) — Integrations with AI provider APIs (Anthropic,
     OpenAI) that filter tool lists based on authorization decisions.

  ## Quick Start

  Add `SkillKit.Supervisor` to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {SkillKit.Supervisor, []}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Usage

  Once the supervision tree is running (see Quick Start above), you can
  register and look up skills. The single-argument forms below use the
  default registry name (`SkillKit.Registry`):

      skill = %SkillKit.Skill{name: "files:read", namespace: "files"}
      :ok = SkillKit.Registry.register(skill)
      {:ok, skill} = SkillKit.Registry.get_skill("files:read")

  If you started the registry with a custom name, pass it explicitly:

      :ok = SkillKit.Registry.register(MyApp.SkillRegistry, skill)
      {:ok, skill} = SkillKit.Registry.get_skill(MyApp.SkillRegistry, "files:read")

  ## Configuration

  All configuration is passed via `start_link/1` opts — SkillKit never reads
  from the application environment. This makes it safe to use in libraries and
  umbrella apps without polluting the application configuration namespace.
  """

  alias SkillKit.Agent
  alias SkillKit.AgentRef
  alias SkillKit.LLM.Message

  @type agent :: AgentRef.t()

  @doc """
  Starts a new agent from the given definition.

  Returns `{:ok, agent_ref}` where `agent_ref` is an opaque reference
  used with `send_message/2` and `stop_agent/1`.

  ## Options

    * `:caller` — the pid to receive streamed events (default: `self()`)
    * `:sources` — list of `{module, config}` skill sources (default: `[]`)
    * `:provider` — `{module, config}` LLM provider (default: from app config)
    * `:conversation_store` — `{module, config}` for persisting conversation history (default: `nil`)
    * `:scope` — granted scopes for authorization (default: `nil`)

  """
  @spec start_agent(Agent.Definition.t(), keyword()) :: {:ok, agent()} | {:error, term()}
  def start_agent(definition, opts \\ []) do
    caller = Keyword.get(opts, :caller, self())
    sources = Keyword.get(opts, :sources, [])
    provider = Keyword.get(opts, :provider)
    conversation_store = Keyword.get(opts, :conversation_store)
    scope = Keyword.get(opts, :scope)

    registry_name = :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"

    agent_opts = %{
      agent_name: definition.name,
      definition: definition,
      depth: 0,
      parent_name: nil,
      scope: scope,
      sources: sources,
      registry: registry_name,
      provider: provider,
      caller: caller,
      conversation_store: conversation_store
    }

    case Agent.start_link(agent_opts) do
      {:ok, sup_pid} ->
        {:ok, %AgentRef{name: definition.name, registry: registry_name, supervisor_pid: sup_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a user message to the agent referenced by `agent`.

  Returns `:ok` if the message was delivered, or `{:error, :not_found}`
  if the agent's mailbox process cannot be found.
  """
  @spec send_message(agent(), String.t()) :: :ok | {:error, :not_found}
  def send_message(%AgentRef{} = agent, content) when is_binary(content) do
    message = %Message.User{content: content}

    try do
      case Registry.lookup(agent.registry, {agent.name, :mailbox}) do
        [{pid, _}] ->
          GenServer.cast(pid, {:message, message})
          :ok

        [] ->
          {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc false
  @spec start_subagent(Agent.Definition.t(), keyword(), keyword()) :: {:ok, agent()} | {:error, term()}
  def start_subagent(definition, parent_opts, opts \\ []) do
    depth = Keyword.fetch!(parent_opts, :depth)
    parent_name = Keyword.fetch!(parent_opts, :parent_name)
    parent_registry = Keyword.fetch!(parent_opts, :parent_registry)
    sources = Keyword.get(opts, :sources, [])
    provider = Keyword.get(opts, :provider)

    registry_name = :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"

    agent_opts = %{
      agent_name: definition.name,
      definition: definition,
      depth: depth + 1,
      parent_name: parent_name,
      scope: nil,
      sources: sources,
      registry: registry_name,
      provider: provider,
      caller: nil,
      parent_registry: parent_registry
    }

    case Agent.start_link(agent_opts) do
      {:ok, sup_pid} ->
        {:ok, %AgentRef{name: definition.name, registry: registry_name, supervisor_pid: sup_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a running agent and all its child processes.
  """
  @spec stop_agent(agent()) :: :ok
  def stop_agent(%AgentRef{supervisor_pid: pid}) do
    Supervisor.stop(pid)
  end
end
