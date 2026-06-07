defmodule SkillKit.Types.UserMessage do
  @moduledoc "A user message in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t() | [map()]
        }

  @enforce_keys [:content]
  defstruct [:agent, :content]
end
