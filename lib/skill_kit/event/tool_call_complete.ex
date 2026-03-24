defmodule SkillKit.Event.ToolCallComplete do
  @moduledoc "A tool call is fully parsed with input."
  @enforce_keys [:id, :name, :input]
  defstruct [:agent, :id, :name, :input]
end
