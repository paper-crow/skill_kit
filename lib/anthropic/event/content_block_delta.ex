defmodule Anthropic.Event.ContentBlockDelta do
  @moduledoc false
  @enforce_keys [:index, :delta]
  defstruct [:index, :delta]
end
