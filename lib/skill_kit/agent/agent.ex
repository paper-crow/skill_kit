defmodule SkillKit.Agent do
  @moduledoc """
  Top-level supervisor for an agent.

  Starts three children under `:one_for_one`:
  - `Registry` — process registry for agent components
  - `SkillKit.Catalog` — provider aggregation, authorization, tool definitions
  - `Agent.Core` — mailbox, server, subagent supervisor (`:rest_for_one`)

  ## Starting an agent

      opts = %{
        agent_name: "project-a",
        definition: %Agent.Definition{...},
        depth: 0,
        parent_name: nil,
        scope: %MyApp.Scope{...},
        skills: [{SkillKit.Kit.Local, dir: "skills"}],
        registry: Agent.Registry
      }

      {:ok, pid} = SkillKit.Agent.start_link(opts)
  """

  use Supervisor

  alias SkillKit.Agent.Core

  @type opts :: %{
          :agent_name => String.t(),
          :definition => SkillKit.Agent.Definition.t(),
          :depth => non_neg_integer(),
          :parent_name => String.t() | nil,
          :scope => term(),
          :skills => [{module(), keyword()}],
          :registry => atom(),
          optional(:caller) => pid() | nil,
          optional(:parent_registry) => atom() | nil,
          optional(:conversation_store) => {module(), keyword()} | nil
        }

  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    %{
      agent_name: agent_name,
      definition: definition,
      depth: depth,
      parent_name: parent_name,
      scope: scope,
      skills: skills,
      registry: registry
    } = opts

    caller = Map.get(opts, :caller)
    parent_registry = Map.get(opts, :parent_registry)
    conversation_store = Map.get(opts, :conversation_store)

    server_opts = [skills: skills]
    server_opts = if caller, do: Keyword.put(server_opts, :caller, caller), else: server_opts

    server_opts =
      if parent_registry,
        do: Keyword.put(server_opts, :parent_registry, parent_registry),
        else: server_opts

    server_opts =
      if conversation_store,
        do: Keyword.put(server_opts, :conversation_store, conversation_store),
        else: server_opts

    children = [
      {Registry, keys: :unique, name: registry},
      {SkillKit.Catalog,
       name: {:via, Registry, {registry, {agent_name, :catalog}}}, providers: skills, scope: scope},
      {Core, {agent_name, definition, depth, parent_name, scope, registry, server_opts}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
