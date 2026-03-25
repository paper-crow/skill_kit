defmodule SkillKit.Agent.Infrastructure do
  @moduledoc """
  Supervisor for agent infrastructure: the skill registry.

  Uses `:one_for_one`. Isolated from Agent.Core so a skill registry
  crash doesn't take down the agent's conversation state.
  """

  use Supervisor

  def start_link({agent_name, definition, skills, registry, kits}) do
    Supervisor.start_link(__MODULE__, {agent_name, definition, skills, registry, kits})
  end

  @impl true
  def init({agent_name, _definition, skills, registry, kits}) do
    skill_registry_name = {:via, Registry, {registry, {agent_name, :skill_registry}}}

    children = [
      {SkillKit.Supervisor,
       name: {:via, Registry, {registry, {agent_name, :skill_supervisor}}},
       registry_name: skill_registry_name,
       skills: skills,
       kits: kits}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
