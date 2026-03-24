defmodule SkillKit.Types.AssistantMessage do
  @moduledoc "An assistant response in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t() | nil,
          tool_calls: [SkillKit.Types.ToolCall.t()]
        }

  defstruct [:agent, :content, tool_calls: []]
end
