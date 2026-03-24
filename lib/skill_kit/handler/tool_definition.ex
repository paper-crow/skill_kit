defmodule SkillKit.Handler.ToolDefinition do
  @moduledoc "Describes a handler as a tool the LLM can call."

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @enforce_keys [:name, :description, :input_schema]
  defstruct [:name, :description, :input_schema]
end
