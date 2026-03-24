defmodule Anthropic.Event.MessageStart do
  @moduledoc """
  Represents the `message_start` SSE event from the Anthropic streaming API.

  This is the first event in every streamed response. It carries the
  message `id` and initial `usage` statistics (input tokens consumed).
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          usage: map() | nil
        }

  defstruct [:id, :usage]
end
