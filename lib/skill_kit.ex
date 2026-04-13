defmodule SkillKit do
  @moduledoc """
  SkillKit — an Elixir framework for building LLM agent systems.

  This module is the public API for starting agents, sending messages,
  and receiving streamed responses.

  ## Quick Start

      {:ok, agent} = SkillKit.start_agent("agents/my-agent",
        skills: ["skills"],
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
    * `%SkillKit.Event.InputRequested{agent: name, tool_call_id: id}` — tool suspended, needs input
    * `%SkillKit.Event.Error{agent: name, reason: reason}` — LLM or execution error

  ## Configuration

      config :skill_kit, SkillKit.LLM,
        providers: [
          anthropic: SkillKit.LLM.Anthropic
        ],
        default_provider: :anthropic
  """

  alias SkillKit.Agent
  alias SkillKit.AgentRef
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Runtime
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  @type agent :: AgentRef.t()

  @valid_opts [:skills, :runtime, :scope, :conversation_store, :caller, :name]

  @doc """
  Starts a new agent.

  The first argument identifies the agent. It accepts:
  - `"path"` — string path, resolved as `{Kit.Local, dir: "path"}`
  - `MyModule` — bare module, resolved as `{MyModule, []}`
  - `{module, opts}` — a kit provider tuple

  When the agent is loaded from a kit provider, the kit's skills and
  sub-agents are automatically included in the tool pool.

  Returns `{:ok, agent_ref}` where `agent_ref` is an opaque reference
  used with `send_message/2` and `stop_agent/1`.

  ## Options

    * `:skills` — list of skill sources (default: `[]`)
    * `:runtime` — `{module, config}` for agent spawning (default: `{Runtime.Local, []}`)
    * `:scope` — authorization scope (default: `nil`)
    * `:conversation_store` — `{module, config}` for persistence (default: `nil`)
    * `:caller` — pid for events (default: `self()`)
    * `:name` — override agent name

  """
  @spec start_agent(Agent.t() | String.t() | {module(), keyword()} | module()) ::
          {:ok, agent()} | {:error, term()}
  def start_agent(source) do
    start_agent(source, [])
  end

  @spec start_agent(Agent.t() | String.t() | {module(), keyword()} | module(), keyword()) ::
          {:ok, agent()} | {:error, term()}
  def start_agent(source, opts) do
    source
    |> resolve_and_build(opts)
    |> assign_caller()
    |> Runtime.start_agent()
  end

  defp resolve_and_build(source, opts) do
    Keyword.validate!(opts, @valid_opts)

    agent = resolve_agent(source)
    skills = normalize_skills(Keyword.get(opts, :skills, []))
    agent_provider = agent_as_provider(source)
    all_skills = merge_agent_provider(agent_provider, skills)

    %{
      agent
      | name: Keyword.get(opts, :name, agent.name),
        skills: all_skills,
        runtime: Keyword.get(opts, :runtime, agent.runtime),
        scope: Keyword.get(opts, :scope, agent.scope),
        conversation_store: Keyword.get(opts, :conversation_store, agent.conversation_store),
        caller: Keyword.get(opts, :caller),
        registry: :"skill_kit_registry_#{:erlang.unique_integer([:positive])}"
    }
  end

  defp assign_caller(%{caller: nil} = agent) do
    %{agent | caller: self()}
  end

  defp assign_caller(agent), do: agent

  # -------------------------------------------------------------------
  # Agent resolution
  # -------------------------------------------------------------------

  defp resolve_agent(%Agent{} = definition), do: definition

  defp resolve_agent(path) when is_binary(path) do
    resolve_agent({SkillKit.Kit.Local, dir: path})
  end

  defp resolve_agent(module) when is_atom(module) do
    resolve_agent({module, []})
  end

  defp resolve_agent({module, config}) do
    case module.load_kits(config) do
      {:ok, kits} ->
        kits
        |> Enum.map(& &1.agent)
        |> Enum.find(& &1) ||
          raise "No agent (AGENT.md) found in agent: provider #{inspect(module)}"

      {:error, reason} ->
        raise "Failed to load agent from #{inspect(module)}: #{inspect(reason)}"
    end
  end

  # -------------------------------------------------------------------
  # Skills normalization (string/module/tuple sugar)
  # -------------------------------------------------------------------

  defp normalize_skills(skills) do
    Enum.map(skills, &normalize_skill_entry/1)
  end

  defp normalize_skill_entry(path) when is_binary(path), do: {SkillKit.Kit.Local, dir: path}
  defp normalize_skill_entry(module) when is_atom(module), do: {module, []}
  defp normalize_skill_entry({module, config}), do: {module, config}

  # -------------------------------------------------------------------
  # Auto-include agent kit's tools
  # -------------------------------------------------------------------

  defp agent_as_provider(%Agent{}), do: nil
  defp agent_as_provider(path) when is_binary(path), do: {SkillKit.Kit.Local, dir: path}
  defp agent_as_provider(module) when is_atom(module), do: {module, []}
  defp agent_as_provider({module, config}), do: {module, config}

  defp merge_agent_provider(nil, skills), do: skills
  defp merge_agent_provider(provider, skills), do: [provider | skills]

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
  Responds to a suspended tool call with input.

  When a tool returns `{:pending, state}`, the caller receives an
  `%Event.InputRequested{}` event. Call `respond/3` with the
  `tool_call_id` from the event and the answer to resume execution.
  """
  @spec respond(agent(), String.t(), any()) :: :ok | {:error, :not_found}
  def respond(%AgentRef{} = agent, tool_call_id, answer) do
    case Registry.lookup(agent.registry, {agent.name, :pending_tool, tool_call_id}) do
      [{pid, _}] ->
        send(pid, {:resume, answer})
        :ok

      [] ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
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

  @doc """
  Stops a running agent and all its child processes.
  """
  @spec stop_agent(agent()) :: :ok
  def stop_agent(%AgentRef{supervisor_pid: pid}) do
    Supervisor.stop(pid)
  end
end
