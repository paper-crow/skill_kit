defmodule SkillKit.AgentRef do
  @moduledoc """
  Opaque reference to a running agent.

  Returned by `SkillKit.start_agent/2`. Used with `SkillKit.send_message/2`
  and `SkillKit.stop_agent/1`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          registry: atom(),
          supervisor_pid: pid()
        }

  @enforce_keys [:name, :registry, :supervisor_pid]
  defstruct [:name, :registry, :supervisor_pid]
end
