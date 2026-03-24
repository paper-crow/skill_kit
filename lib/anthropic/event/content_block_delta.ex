defmodule Anthropic.Event.ContentBlockDelta do
  @moduledoc """
  Represents the `content_block_delta` SSE event from the Anthropic streaming API.

  Carries an incremental update for the content block at `index`. For text
  blocks the `delta` has `type: :text_delta`; for tool-use blocks it has
  `type: :input_json_delta` with a partial JSON string.
  """

  @type delta ::
          %{type: :text_delta, text: String.t()}
          | %{type: :input_json_delta, partial_json: String.t()}

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          delta: delta()
        }

  @enforce_keys [:index, :delta]
  defstruct [:index, :delta]
end
