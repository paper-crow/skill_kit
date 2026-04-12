defmodule SkillKit.Agent.Core do
  @moduledoc """
  Supervisor for the core agent processes: Mailbox, Server, SubagentSupervisor.

  Uses `:rest_for_one` — if Mailbox crashes, Server and SubagentSupervisor
  restart. If Server crashes, SubagentSupervisor restarts.
  """

  use Supervisor

  alias SkillKit.Agent.Mailbox
  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SubagentSupervisor

  def start_link(%SkillKit.Agent{} = agent) do
    Supervisor.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    children = [
      {Mailbox, agent},
      {Server, agent},
      {SubagentSupervisor, agent}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
