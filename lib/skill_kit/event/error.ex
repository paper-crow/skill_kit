defmodule SkillKit.Event.Error do
  @moduledoc "An error from the LLM."
  @enforce_keys [:reason]
  defstruct [:agent, :reason]
end
