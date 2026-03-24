defmodule SkillKit.Types.ToolResult do
  @moduledoc "The result of executing a tool."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          tool_call_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  @enforce_keys [:tool_call_id, :content]
  defstruct [:agent, :tool_call_id, :content, is_error: false]
end
