defmodule SkillKit.Response.Empty do
  @moduledoc """
  Describes an LLM response with no content and no tool calls.

  This can happen when the LLM acknowledges a tool result but has
  nothing to add — it produces a stop event without any text or tool use.
  """

  defstruct []
end
