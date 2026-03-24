defmodule Anthropic.Event.MessageDelta do
  @moduledoc """
  Represents the `message_delta` SSE event from the Anthropic streaming API.

  Emitted after all content blocks have closed. Carries the `stop_reason`
  (`:end_turn` or `:tool_use`) and final `usage` statistics (output tokens).
  """

  @type stop_reason :: :end_turn | :tool_use | String.t() | nil

  @type t :: %__MODULE__{
          stop_reason: stop_reason(),
          usage: map() | nil
        }

  defstruct [:stop_reason, :usage]
end
