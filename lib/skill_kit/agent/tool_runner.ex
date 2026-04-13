defmodule SkillKit.Agent.ToolRunner do
  @moduledoc """
  DynamicSupervisor for tool call execution. Public API for batch
  tool execution via `execute_all/2`.

  Each tool call runs as a supervised child in parallel. Results and
  side effects are collected and applied to state sequentially after
  all children complete.

  Suspended tools block their child process until `SkillKit.respond/3`
  delivers the answer. The child registers itself in the agent's Registry
  so respond can route directly to it. `execute_all` naturally blocks
  until every child has a resolved result.

  Uses `:temporary` restart strategy — children are not restarted on
  crash. Crashed children produce error results.
  """

  use DynamicSupervisor

  alias SkillKit.Agent.Server
  alias SkillKit.Agent.ToolDispatch
  alias SkillKit.Event.InputRequested
  alias SkillKit.ToolExecution
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

  Each tool call runs in its own child process. If a tool suspends
  (`{:pending, state}`), the child blocks until an answer arrives via
  `SkillKit.respond/3`. Returns only when every tool has a resolved
  result.

  State is the first argument for pipelining.
  """
  @spec execute_all(Server.t(), [ToolCall.t()]) :: {[ToolResult.t()], Server.t()}
  def execute_all(state, tool_calls) do
    batch_meta = %{
      agent_name: state.agent.name,
      tool_count: length(tool_calls),
      tool_names: Enum.map(tool_calls, & &1.name)
    }

    SkillKit.Telemetry.span([:tool_batch], batch_meta, fn ->
      {results, new_state} = do_execute_all(state, tool_calls)
      {{results, new_state}, %{}, batch_meta}
    end)
  end

  defp do_execute_all(state, tool_calls) do
    runner = lookup_runner(state)
    caller = self()

    refs_and_monitors =
      Enum.map(tool_calls, fn tc ->
        ref = make_ref()

        {:ok, pid} =
          start_child(runner, fn ->
            result = ToolDispatch.execute_one(state, tc)
            resolved = resolve_result(result, state, tc)
            send(caller, {:tool_result, ref, tc, resolved})
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

  # --- Suspension Resolution ---

  # Tool completed normally — pass through
  defp resolve_result({_result, _side_effects} = resolved, _state, _tc), do: resolved

  # Tool suspended — register, notify, block until fully resolved
  defp resolve_result({:suspended, execution, side_effects}, state, tc) do
    # Register before notifying so respond/3 can find us immediately
    Registry.register(state.agent.registry, {state.agent.name, :pending_tool, tc.id}, nil)

    result = await_resume(execution, side_effects, state, tc)

    Registry.unregister(state.agent.registry, {state.agent.name, :pending_tool, tc.id})

    result
  end

  defp await_resume(execution, side_effects, state, tc) do
    notify_caller(state, %InputRequested{
      agent: state.agent.name,
      tool_call_id: tc.id,
      tool_name: tc.name,
      suspended_state: execution.suspended_state
    })

    receive do
      {:resume, answer} ->
        case ToolExecution.resume(execution, answer) do
          {:pending, new_execution} ->
            await_resume(new_execution, side_effects, state, tc)

          {:ok, resumed} ->
            result = %ToolResult{
              tool_call_id: tc.id,
              content: format_result(resumed.result)
            }

            notify_caller(state, %{result | agent: state.agent.name})
            {result, side_effects}

          {:error, resumed} ->
            result = %ToolResult{
              tool_call_id: tc.id,
              content: "Resume failed: #{inspect(resumed.result)}",
              is_error: true
            }

            notify_caller(state, %{result | agent: state.agent.name})
            {result, side_effects}
        end
    end
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

  defp process_result(state, _tc, {result, side_effects}) do
    state = apply_side_effects(state, side_effects)
    notify_caller(state, %{result | agent: state.agent.name})
    {result, state}
  end

  # --- Side Effect Application ---

  defp apply_side_effects(state, side_effects) do
    Enum.reduce(side_effects, state, &apply_effect/2)
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

  defp format_result(result) when is_binary(result), do: result
  defp format_result({:ok, output}), do: to_string(output)
  defp format_result(other), do: inspect(other)
end
