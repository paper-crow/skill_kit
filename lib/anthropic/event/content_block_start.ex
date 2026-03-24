defmodule Anthropic.Event.ContentBlockStart do
  @moduledoc """
  Represents the `content_block_start` SSE event from the Anthropic streaming API.

  Emitted when a new content block opens (text or tool-use). The `index`
  identifies which block in the message content array is starting, and
  `content_block` describes its type and any initial metadata.
  """

  @type content_block ::
          %{type: :text, text: String.t()} | %{type: :tool_use, id: String.t(), name: String.t()}

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          content_block: content_block()
        }

  @enforce_keys [:index, :content_block]
  defstruct [:index, :content_block]
end
