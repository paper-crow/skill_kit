defmodule SkillKit.Types.SystemMessage do
  @moduledoc "A system message in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t()
        }

  @enforce_keys [:content]
  defstruct [:agent, :content]
end
