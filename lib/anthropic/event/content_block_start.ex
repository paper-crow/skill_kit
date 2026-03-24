defmodule Anthropic.Event.ContentBlockStart do
  @moduledoc false
  @enforce_keys [:index, :content_block]
  defstruct [:index, :content_block]
end
