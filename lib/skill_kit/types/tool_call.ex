defmodule SkillKit.Types.ToolCall do
  @moduledoc "A tool invocation from the assistant."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input]
end
