defmodule SkillKit.Agent.ToolRunner do
  @moduledoc """
  DynamicSupervisor for tool call execution. Public API for batch
  tool execution via `execute_all/2`.

  Each tool call runs as a supervised child in parallel. Results and
  side effects are collected and applied to state sequentially after
  all children complete.

  Uses `:temporary` restart strategy — children are not restarted on
  crash. Crashed children produce error results.
  """

  use DynamicSupervisor

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.ToolDispatch
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult

  @doc "Starts the ToolRunner supervisor for the given agent."
  @spec start_link(SkillKit.Agent.t()) :: Supervisor.on_start()
  def start_link(%SkillKit.Agent{} = agent) do
    DynamicSupervisor.start_link(__MODULE__, :ok,
      name: {:via, Registry, {agent.registry, {agent.name, :tool_runner}}}
    )
  end

  @doc """
  Executes a batch of tool calls in parallel under supervised children.

  Each tool call runs in its own child process. Results and side effects
  are collected and applied to state. Returns `{results, updated_state}`.

  State is the first argument for pipelining.
  """
  @spec execute_all(Server.t(), [ToolCall.t()]) :: {[ToolResult.t()], Server.t()}
  def execute_all(state, tool_calls) do
    runner = lookup_runner(state)
    caller = self()

    refs_and_monitors =
      Enum.map(tool_calls, fn tc ->
        ref = make_ref()

        {:ok, pid} =
          start_child(runner, fn ->
            result = ToolDispatch.execute_one(state, tc)
            send(caller, {:tool_result, ref, tc, result})
          end)

        mon = Process.monitor(pid)
        {ref, tc, mon}
      end)

    results_with_effects = collect_results(refs_and_monitors)

    Enum.map_reduce(results_with_effects, state, fn {tc, result}, acc ->
      process_result(acc, tc, result)
    end)
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

  # --- Result Collection ---

  defp collect_results(refs_and_monitors) do
    Enum.map(refs_and_monitors, fn {ref, tc, mon} ->
      receive do
        {:tool_result, ^ref, ^tc, result} ->
          Process.demonitor(mon, [:flush])
          {tc, result}

        {:DOWN, ^mon, :process, _pid, reason} ->
          error_result = %ToolResult{
            tool_call_id: tc.id,
            content: "Tool execution failed: #{inspect(reason)}",
            is_error: true
          }

          {tc, {error_result, []}}
      end
    end)
  end

  # --- Result Processing ---

  defp process_result(state, tc, {:suspended, execution, side_effects}) do
    state = apply_side_effects(state, side_effects)

    event = %SkillKit.Event.InputRequested{
      agent: state.agent.name,
      tool_call_id: tc.id,
      tool_name: tc.name,
      suspended_state: execution.suspended_state
    }

    notify_caller(state, event)

    pending =
      Map.put(state.pending_tools, tc.id, %{
        execution: execution,
        tool_call: tc
      })

    result = %ToolResult{tool_call_id: tc.id, content: "Waiting for input."}
    notify_caller(state, %{result | agent: state.agent.name})

    {result, %{state | pending_tools: pending}}
  end

  defp process_result(state, _tc, {result, side_effects}) do
    state = apply_side_effects(state, side_effects)
    notify_caller(state, %{result | agent: state.agent.name})
    {result, state}
  end

  # --- Side Effect Application ---

  defp apply_side_effects(state, side_effects) do
    Enum.reduce(side_effects, state, &apply_effect/2)
  end

  defp apply_effect({:activate_skill, skill}, state) do
    %{state | activated_skills: [skill | state.activated_skills]}
  end

  defp apply_effect({:subagent, server_pid, entry}, state) do
    monitor_ref = Process.monitor(server_pid)
    entry = Map.put(entry, :monitor_ref, monitor_ref)
    %{state | subagents: Map.put(state.subagents, server_pid, entry)}
  end

  # --- Helpers ---

  defp notify_caller(%{agent: %{caller: nil}}, _event), do: :ok

  defp notify_caller(%{agent: %{caller: pid}}, event) do
    send(pid, event)
  end

  defp lookup_runner(state) do
    {:via, Registry, {state.agent.registry, {state.agent.name, :tool_runner}}}
  end
end
