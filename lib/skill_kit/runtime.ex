defmodule SkillKit.Runtime do
  @moduledoc """
  Behaviour for agent runtimes.

  A runtime controls how an agent supervision tree is started. The
  default `SkillKit.Runtime.Local` starts agents in the current node.
  Alternative runtimes (e.g., FLAME) can start agents on remote nodes.

  The behaviour defines one callback: `start_agent/2`. The public
  function `start_agent/1` reads the runtime from the Agent struct,
  dispatches to the callback, and wraps the result in an `AgentRef`.
  """

  alias SkillKit.AgentRef

  @callback start_agent(SkillKit.Agent.t(), keyword()) :: {:ok, pid()} | {:error, term()}

  @doc """
  Starts an agent using the runtime configured on its struct.

  Returns `{:ok, %AgentRef{}}` or `{:error, reason}`.
  """
  @spec start_agent(SkillKit.Agent.t()) :: {:ok, AgentRef.t()} | {:error, term()}
  def start_agent(%SkillKit.Agent{} = agent) do
    {mod, config} = agent.runtime

    with {:ok, sup_pid} <- apply(mod, :start_agent, [agent, config]) do
      {:ok,
       %AgentRef{
         name: agent.name,
         registry: agent.registry,
         supervisor_pid: sup_pid
       }}
    end
  end
end
