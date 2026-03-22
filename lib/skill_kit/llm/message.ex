defmodule SkillKit.LLM.Message do
  @moduledoc """
  Provider-agnostic message types for LLM conversations.

  The orchestration layer builds conversations using these structs.
  LLM adapters translate to/from provider-specific formats.

  ## Message Types

  - `User` — a message from the user or injected context
  - `Assistant` — a response from the LLM, optionally containing tool calls
  - `ToolCall` — a tool invocation requested by the LLM (embedded in Assistant)
  - `ToolResult` — the result of executing a tool call
  - `System` — injected context (subagent results, background task completions)
  """

  defmodule User do
    @moduledoc "A message from the user or injected context."
    @type t :: %__MODULE__{content: String.t()}
    @enforce_keys [:content]
    defstruct [:content]
  end

  defmodule Assistant do
    @moduledoc "A response from the LLM, optionally containing tool calls."
    @type t :: %__MODULE__{
            content: String.t() | nil,
            tool_calls: [SkillKit.LLM.Message.ToolCall.t()]
          }
    defstruct [:content, tool_calls: []]
  end

  defmodule ToolCall do
    @moduledoc "A tool invocation requested by the LLM. Embedded in Assistant.tool_calls."
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            input: map()
          }
    @enforce_keys [:id, :name, :input]
    defstruct [:id, :name, :input]
  end

  defmodule ToolResult do
    @moduledoc "The result of executing a tool call."
    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            content: String.t(),
            is_error: boolean()
          }
    @enforce_keys [:tool_call_id, :content]
    defstruct [:tool_call_id, :content, is_error: false]
  end

  defmodule System do
    @moduledoc "Injected context — subagent results, background task completions."
    @type t :: %__MODULE__{content: String.t()}
    @enforce_keys [:content]
    defstruct [:content]
  end

  @type t :: User.t() | Assistant.t() | ToolResult.t() | System.t()
end
