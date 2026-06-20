defmodule SkillKit.Event.Usage do
  @moduledoc "Token usage counts from the LLM."
  defstruct [
    :agent,
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0
  ]
end
