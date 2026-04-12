defmodule SkillKit.Runtime.Local do
  @moduledoc """
  Local runtime — starts agent supervision trees in the current node.

  This is the default runtime. It calls `Agent.Supervisor.start_link/1`
  directly, starting the full supervision tree (Registry, Catalog, Core)
  in the current BEAM node.
  """

  @behaviour SkillKit.Runtime

  @impl true
  def start_agent(agent, _config) do
    SkillKit.Agent.Supervisor.start_link(agent)
  end
end
