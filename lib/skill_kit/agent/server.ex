defmodule SkillKit.Agent.Server do
  @moduledoc """
  Core agent process. Drives the LLM loop, manages subagents.

  This is the skeleton — struct, init, and registry registration.
  The LLM loop (run_agent_loop) will be added in a future plan.
  """

  use GenServer

  alias SkillKit.Agent.Definition

  defstruct [
    :agent_name,
    :parent_name,
    :definition,
    :depth,
    :scope,
    :registry,
    messages: [],
    subagents: %{},
    pending_requests: %{}
  ]

  @type t :: %__MODULE__{
          agent_name: String.t(),
          parent_name: String.t() | nil,
          definition: Definition.t(),
          depth: non_neg_integer(),
          scope: term(),
          registry: atom(),
          messages: list(),
          subagents: map(),
          pending_requests: map()
        }

  def start_link({agent_name, definition, depth, parent_name, scope, registry}) do
    GenServer.start_link(__MODULE__, {agent_name, definition, depth, parent_name, scope, registry})
  end

  @impl true
  def init({agent_name, definition, depth, parent_name, scope, registry}) do
    Registry.register(registry, {agent_name, :server}, [])

    {:ok, %__MODULE__{
      agent_name: agent_name,
      parent_name: parent_name,
      definition: definition,
      depth: depth,
      scope: scope,
      registry: registry
    }}
  end

  # Stub: store messages for now. The LLM loop replaces this.
  @impl true
  def handle_info({:mailbox_flush, new_messages}, state) do
    {:noreply, %{state | messages: state.messages ++ new_messages}}
  end

end
