defmodule Anthropic.Event.MessageDelta do
  @moduledoc false
  defstruct [:stop_reason, :usage]
end
