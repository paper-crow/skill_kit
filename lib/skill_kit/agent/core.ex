defmodule SkillKit.Agent.Core do
  @moduledoc """
  Supervisor for the core agent processes: Mailbox, Server, SubagentSupervisor.

  Uses `:rest_for_one` — if Mailbox crashes, Server and SubagentSupervisor
  restart. If Server crashes, SubagentSupervisor restarts. Orphaned
  subagents with no parent should not continue running.
  """

  use Supervisor

  alias SkillKit.Agent.Mailbox
  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SubagentSupervisor

  def start_link({agent_name, definition, depth, parent_name, scope, registry}) do
    start_link({agent_name, definition, depth, parent_name, scope, registry, []})
  end

  def start_link({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    Supervisor.start_link(__MODULE__, {agent_name, definition, depth, parent_name, scope, registry, opts})
  end

  @impl true
  def init({agent_name, definition, depth, parent_name, scope, registry, opts}) do
    children = [
      {Mailbox, {agent_name, definition.mailbox, registry}},
      {Server, {agent_name, definition, depth, parent_name, scope, registry, opts}},
      {SubagentSupervisor, {agent_name, registry}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
