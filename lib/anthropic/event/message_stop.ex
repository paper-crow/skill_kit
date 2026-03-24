defmodule Anthropic.Event.MessageStop do
  @moduledoc """
  Represents the `message_stop` SSE event from the Anthropic streaming API.

  The final event in every streamed response, signalling that the message
  is fully complete. Carries no fields.
  """

  @type t :: %__MODULE__{}

  defstruct []
end
