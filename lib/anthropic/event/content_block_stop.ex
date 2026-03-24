defmodule Anthropic.Event.ContentBlockStop do
  @moduledoc """
  Represents the `content_block_stop` SSE event from the Anthropic streaming API.

  Emitted when the content block at `index` is complete. No further deltas
  will be sent for that block.
  """

  @type t :: %__MODULE__{
          index: non_neg_integer()
        }

  @enforce_keys [:index]
  defstruct [:index]
end
