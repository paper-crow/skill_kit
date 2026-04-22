defmodule SkillKit.Webhook.Registry do
  @moduledoc """
  Per-node directory of running agents the webhook Plug can dispatch to.

  Populated automatically by `SkillKit.Webhook.Lifecycle` when an agent
  boots (`:pre_agent` hook). Each attached agent's per-agent Registry
  process is monitored; `:DOWN` purges the entry. Re-attach (after an
  agent restart) overwrites the prior entry and replaces the monitor,
  guarding against stale `:DOWN` messages deleting the fresh binding.

  Two ETS tables keyed off the supervisor name:

  - `agents`   : `agent_name → %SkillKit.Agent{}`
  - `monitors` : `monitor_ref → agent_name`
  """

  use GenServer

  alias SkillKit.Agent, as: SkAgent

  # -- Public API -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Binds `agent.name` to the running `%Agent{}` and monitors its per-agent
  registry process. Called by `Webhook.Lifecycle` from the `:pre_agent`
  hook; hosts should not call this directly.
  """
  @spec attach(SkAgent.t(), keyword()) :: :ok
  def attach(%SkAgent{} = agent, opts) do
    name = Keyword.fetch!(opts, :registry)
    GenServer.call(name, {:attach, agent})
  end

  @spec detach(String.t(), keyword()) :: :ok
  def detach(agent_name, opts) when is_binary(agent_name) do
    name = Keyword.fetch!(opts, :registry)
    GenServer.call(name, {:detach, agent_name})
  end

  @spec whereis(String.t(), keyword()) :: {:ok, SkAgent.t()} | {:error, :agent_not_running}
  def whereis(agent_name, opts) when is_binary(agent_name) do
    table = agents_table(Keyword.fetch!(opts, :registry))

    case :ets.lookup(table, agent_name) do
      [{^agent_name, %SkAgent{} = agent}] -> {:ok, agent}
      [] -> {:error, :agent_not_running}
    end
  end

  # -- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    agents =
      :ets.new(agents_table(name), [:named_table, :protected, :set, read_concurrency: true])

    monitors = :ets.new(monitors_table(name), [:named_table, :protected, :set])
    {:ok, %{agents: agents, monitors: monitors}}
  end

  @impl true
  def handle_call({:attach, %SkAgent{} = agent}, _from, state) do
    drop_existing(agent.name, state)
    ref = monitor_agent(agent)
    :ets.insert(state.agents, {agent.name, agent})
    :ets.insert(state.monitors, {ref, agent.name})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:detach, agent_name}, _from, state) do
    drop_existing(agent_name, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case :ets.take(state.monitors, ref) do
      [{^ref, agent_name}] -> drop_if_current(agent_name, ref, state)
      [] -> :ok
    end

    {:noreply, state}
  end

  # -- Helpers --------------------------------------------------------------

  defp monitor_agent(%SkAgent{registry: reg}) do
    case Process.whereis(reg) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> make_ref()
    end
  end

  defp drop_existing(agent_name, state) do
    case :ets.lookup(state.agents, agent_name) do
      [] ->
        :ok

      [{^agent_name, %SkAgent{}}] ->
        :ets.delete(state.agents, agent_name)
        demonitor_refs_for(agent_name, state)
    end
  end

  defp demonitor_refs_for(agent_name, state) do
    refs =
      state.monitors
      |> :ets.match_object({:"$1", agent_name})
      |> Enum.map(&elem(&1, 0))

    Enum.each(refs, fn ref ->
      Process.demonitor(ref, [:flush])
      :ets.delete(state.monitors, ref)
    end)
  end

  defp drop_if_current(agent_name, _ref, state) do
    # Only delete the agents-row if no other monitor is still bound to it.
    # After re-attach the name has a different current ref; this stale :DOWN
    # doesn't match, so we leave the agents-row alone.
    case :ets.match_object(state.monitors, {:"$1", agent_name}) do
      [] -> :ets.delete(state.agents, agent_name)
      _still_attached -> :ok
    end
  end

  defp agents_table(supervisor_name), do: Module.concat(supervisor_name, Agents)
  defp monitors_table(supervisor_name), do: Module.concat(supervisor_name, Monitors)
end
