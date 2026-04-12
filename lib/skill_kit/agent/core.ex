defmodule SkillKit.Agent.Core do
  @moduledoc """
  Supervisor for the core agent processes: Mailbox, Server, ToolRunner.

  Uses `:rest_for_one` — if Mailbox crashes, Server and ToolRunner
  restart. If Server crashes, ToolRunner restarts. In-flight tool
  calls and subagents should not continue without a Server.
  """

  use Supervisor

  alias SkillKit.Agent.Mailbox
  alias SkillKit.Agent.Server
  alias SkillKit.Agent.ToolRunner

  def start_link(%SkillKit.Agent{} = agent) do
    Supervisor.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    children = [
      {Mailbox, agent},
      {Server, agent},
      {ToolRunner, agent}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
