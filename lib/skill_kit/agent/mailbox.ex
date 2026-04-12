defmodule SkillKit.Agent.Mailbox do
  @moduledoc """
  Buffers incoming messages and flushes to Agent.Server.

  Flushes after either a size threshold or interval — whichever
  comes first. Discovers the Server via Registry lookup at flush
  time, not at init (solves rest_for_one startup ordering).
  """

  use GenServer

  defstruct [
    :agent_name,
    :registry,
    :max_messages,
    :flush_interval,
    :timer_ref,
    messages: []
  ]

  def start_link(%SkillKit.Agent{} = agent) do
    GenServer.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    Registry.register(agent.registry, {agent.name, :mailbox}, [])

    {:ok,
     %__MODULE__{
       agent_name: agent.name,
       registry: agent.registry,
       max_messages: agent.mailbox.max_messages,
       flush_interval: agent.mailbox.flush_interval,
       timer_ref: schedule_flush(agent.mailbox.flush_interval)
     }}
  end

  @impl true
  def handle_cast({:message, message}, state) do
    messages = [message | state.messages]
    state = %{state | messages: messages}

    if length(messages) >= state.max_messages do
      {:noreply, flush(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, flush(state)}
  end

  defp flush(%{messages: []} = state) do
    %{state | timer_ref: schedule_flush(state.flush_interval)}
  end

  defp flush(state) do
    cancel_timer(state.timer_ref)

    case Registry.lookup(state.registry, {state.agent_name, :server}) do
      [{server_pid, _}] ->
        send(server_pid, {:mailbox_flush, Enum.reverse(state.messages)})

      [] ->
        :ok
    end

    %{state | messages: [], timer_ref: schedule_flush(state.flush_interval)}
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
