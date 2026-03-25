defmodule SkillKit do
  @moduledoc """
  SkillKit — an Elixir framework for building LLM agent systems.

  This module is the public API for starting agents, sending messages,
  and receiving streamed responses.

  ## Quick Start

      {:ok, agent} = SkillKit.start_agent(definition,
        skills: [{SkillKit.Kit.Local, dirs: ["skills"]}],
        caller: self()
      )

      :ok = SkillKit.send_message(agent, "Hello")

      receive do
        %SkillKit.Event.Delta{text: text} -> IO.write(text)
        %SkillKit.Types.AssistantMessage{content: text} -> IO.puts("Done.")
        %SkillKit.Event.Error{reason: reason} -> IO.puts("Error")
      end

      SkillKit.stop_agent(agent)

  ## Events

  The caller process receives structs directly:

    * `%SkillKit.Event.Delta{agent: name, text: text}` — real-time text fragment
    * `%SkillKit.Event.ToolCallStart{agent: name, id: id, name: name}` — tool call began
    * `%SkillKit.Event.ToolCallComplete{agent: name, id: id, name: name, input: input}` — tool call parsed
    * `%SkillKit.Types.AssistantMessage{agent: name, content: text}` — complete response at turn end
    * `%SkillKit.Types.ToolResult{agent: name, content: content}` — tool result
    * `%SkillKit.Event.Error{agent: name, reason: reason}` — LLM or execution error

  ## Configuration

      # Default LLM provider
      config :skill_kit, SkillKit.LLM,
        {SkillKit.LLM.Anthropic, [api_key: System.get_env("ANTHROPIC_API_KEY")]}
  """

  alias SkillKit.Agent
  alias SkillKit.AgentRef
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  @type agent :: AgentRef.t()

  @doc """
  Starts a new agent from the given definition.

  Returns `{:ok, agent_ref}` where `agent_ref` is an opaque reference
  used with `send_message/2` and `stop_agent/1`.

  ## Options

    * `:caller` — the pid to receive streamed events (default: `self()`)
    * `:skills` — list of `{module, config}` skill sources (default: `[]`)
    * `:conversation_store` — `{module, config}` for persisting conversation history (default: `nil`)
    * `:scope` — granted scopes for authorization (default: `nil`)

  """
  @spec start_agent(keyword()) :: {:ok, agent()} | {:error, term()}
  def start_agent(opts) when is_list(opts) do
    skills = Keyword.fetch!(opts, :skills)
    kits = load_all_kits(skills)

    case extract_root_agent(kits) do
      {:ok, definition} ->
        opts = Keyword.put(opts, :kits, kits)
        start_agent(definition, opts)

      {:error, _} = error ->
        error
    end
  end

  @spec start_agent(Agent.Definition.t()) :: {:ok, agent()} | {:error, term()}
  def start_agent(%Agent.Definition{} = definition) do
    start_agent(definition, [])
  end

  @spec start_agent(Agent.Definition.t(), keyword()) :: {:ok, agent()} | {:error, term()}
  def start_agent(%Agent.Definition{} = definition, opts) do
    caller = Keyword.get(opts, :caller, self())
    skills = Keyword.get(opts, :skills, [])
    conversation_store = Keyword.get(opts, :conversation_store)
    scope = Keyword.get(opts, :scope)
    kits = Keyword.get(opts, :kits)
    agent_name = Keyword.get(opts, :name, definition.name)

    registry_name = :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"

    agent_opts = %{
      agent_name: agent_name,
      definition: definition,
      depth: 0,
      parent_name: nil,
      scope: scope,
      skills: skills,
      registry: registry_name,
      caller: caller,
      conversation_store: conversation_store,
      kits: kits
    }

    case Agent.start_link(agent_opts) do
      {:ok, sup_pid} ->
        {:ok, %AgentRef{name: agent_name, registry: registry_name, supervisor_pid: sup_pid}}

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
    message = %UserMessage{content: content}

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

  @doc """
  Sends a message and blocks until the agent responds.

  Returns `{:ok, text}` on success, `{:error, reason}` on LLM error,
  or `{:error, :timeout}` if the turn doesn't complete within `timeout` ms.

  Must be called from the process registered as `:caller` in `start_agent/2`.
  Intermediate events (`:delta`, `:tool_call`, `:tool_result`) remain in
  the caller's mailbox and are not consumed.

  ## Examples

      {:ok, "Hello!"} = SkillKit.send_message_sync(agent, "Hi")
      {:error, :timeout} = SkillKit.send_message_sync(agent, "Hi", 100)
  """
  @spec send_message_sync(agent(), String.t(), timeout()) ::
          {:ok, AssistantMessage.t()} | {:error, term()}
  def send_message_sync(%AgentRef{} = agent, content, timeout \\ 5000) do
    case send_message(agent, content) do
      :ok -> await_response(agent.name, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_response(agent_name, timeout) do
    receive do
      %AssistantMessage{agent: ^agent_name} = msg -> {:ok, msg}
      %EventError{agent: ^agent_name, reason: reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc false
  @spec start_subagent(Agent.Definition.t(), keyword(), keyword()) ::
          {:ok, agent()} | {:error, term()}
  def start_subagent(definition, parent_opts, opts \\ []) do
    depth = Keyword.fetch!(parent_opts, :depth)
    parent_name = Keyword.fetch!(parent_opts, :parent_name)
    parent_registry = Keyword.fetch!(parent_opts, :parent_registry)
    skills = Keyword.get(opts, :skills, [])

    registry_name = :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"

    agent_opts = %{
      agent_name: definition.name,
      definition: definition,
      depth: depth + 1,
      parent_name: parent_name,
      scope: nil,
      skills: skills,
      registry: registry_name,
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

  defp load_all_kits(skills) do
    Enum.flat_map(skills, fn {mod, config} ->
      case mod.load_kits(config) do
        {:ok, kits} -> kits
        {:error, _} -> []
      end
    end)
  end

  defp extract_root_agent(kits) do
    root_agents =
      kits
      |> Enum.map(& &1.root_agent)
      |> Enum.reject(&is_nil/1)

    case root_agents do
      [definition] -> {:ok, definition}
      [] -> {:error, :no_root_agent}
      _ -> {:error, :multiple_root_agents}
    end
  end
end
