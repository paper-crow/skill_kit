defmodule SkillKit.Event.ToolCallStart do
  @moduledoc "A tool call has begun (name and id known)."
  @enforce_keys [:id, :name]
  defstruct [:agent, :id, :name]
end
