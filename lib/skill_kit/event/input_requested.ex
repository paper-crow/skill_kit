defmodule SkillKit.Event.InputRequested do
  @moduledoc """
  A tool has suspended execution and is requesting input from the caller.

  The caller should inspect the `suspended_state` for context (e.g., a
  question) and respond via `SkillKit.respond/3` with the tool_call_id.
  """

  @enforce_keys [:tool_call_id]
  defstruct [:agent, :tool_call_id, :tool_name, :suspended_state]
end
