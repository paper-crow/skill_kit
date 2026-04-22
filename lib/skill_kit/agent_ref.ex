defmodule SkillKit.AgentRef do
  @moduledoc """
  Opaque reference to a running agent.

  Returned by `SkillKit.start_agent/2`. Used with `SkillKit.send_message/2`
  and `SkillKit.stop_agent/1`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          registry: atom(),
          supervisor_pid: pid() | nil
        }

  @enforce_keys [:name, :registry, :supervisor_pid]
  defstruct [:name, :registry, :supervisor_pid]

  @doc "Builds an `AgentRef` from an `%Agent{}` struct (registry already set)."
  @spec from_agent(SkillKit.Agent.t()) :: t()
  def from_agent(%SkillKit.Agent{name: name, registry: registry}) do
    %__MODULE__{name: name, registry: registry, supervisor_pid: nil}
  end
end
