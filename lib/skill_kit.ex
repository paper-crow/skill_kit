defmodule SkillKit do
  @moduledoc """
  SkillKit — an Elixir framework for building LLM agent systems.

  This module is the public API for starting agents, sending messages,
  and receiving streamed responses.

  ## Quick Start

      {:ok, agent} = SkillKit.start_agent(definition,
        sources: [{SkillKit.Backend.Filesystem, dirs: ["skills"]}],
        provider: {SkillKit.LLM.Anthropic, [api_key: "sk-..."]},
        caller: self()
      )

      :ok = SkillKit.send_message(agent, "Hello")

      receive do
        {:skill_kit, agent_name, {:delta, text}} -> IO.write(text)
        {:skill_kit, agent_name, {:response, text}} -> IO.puts("Done.")
        {:skill_kit, agent_name, {:error, reason}} -> IO.puts("Error")
      end

      SkillKit.stop_agent(agent)

  ## Events

  The caller process receives these messages:

    * `{:skill_kit, agent_name, {:delta, text}}` — real-time text fragment
    * `{:skill_kit, agent_name, {:response, text}}` — complete text at turn end
    * `{:skill_kit, agent_name, {:tool_call, name, input}}` — tool invocation
    * `{:skill_kit, agent_name, {:tool_result, name, content, is_error}}` — tool result
    * `{:skill_kit, agent_name, {:error, reason}}` — LLM or execution error

  ## Configuration

      # Default executor
      config :skill_kit, :executor, SkillKit.Executor.Shell

      # Default LLM provider
      config :skill_kit, SkillKit.LLM,
        {SkillKit.LLM.Anthropic, [api_key: System.get_env("ANTHROPIC_API_KEY")]}
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
  @spec start_subagent(Agent.Definition.t(), keyword(), keyword()) ::
          {:ok, agent()} | {:error, term()}
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
