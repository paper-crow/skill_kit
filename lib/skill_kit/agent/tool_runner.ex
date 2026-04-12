defmodule SkillKit.Agent.ToolRunner do
  @moduledoc """
  DynamicSupervisor for tool call execution.

  All tool work — immediate tool calls, subagent delegation, and future
  async tools — runs as supervised children under this supervisor.

  Replaces `SubagentSupervisor`. Registered in the agent's Registry
  under `{agent_name, :tool_runner}`.

  Uses `:temporary` restart strategy — children are not restarted on
  crash. The Server monitors each child and handles failures.
  """

  use DynamicSupervisor

  @doc "Starts the ToolRunner supervisor for the given agent."
  @spec start_link(SkillKit.Agent.t()) :: Supervisor.on_start()
  def start_link(%SkillKit.Agent{} = agent) do
    DynamicSupervisor.start_link(__MODULE__, :ok,
      name: {:via, Registry, {agent.registry, {agent.name, :tool_runner}}}
    )
  end

  @doc "Starts a supervised child task under this runner."
  @spec start_child(pid() | GenServer.name(), (-> any())) ::
          {:ok, pid()} | {:error, term()}
  def start_child(runner, fun) when is_function(fun, 0) do
    DynamicSupervisor.start_child(runner, %{
      id: :erlang.unique_integer([:positive]),
      start: {Task, :start_link, [fun]},
      restart: :temporary
    })
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
