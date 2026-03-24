defmodule SkillKit.Event.Done do
  @moduledoc "The LLM turn is complete."
  @enforce_keys [:stop_reason]
  defstruct [:agent, :stop_reason]
end
