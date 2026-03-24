defmodule SkillKit.Event.Delta do
  @moduledoc "A text fragment from the LLM stream."
  @enforce_keys [:text]
  defstruct [:agent, :text]
end
