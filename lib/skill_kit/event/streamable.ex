defprotocol SkillKit.Event.Streamable do
  @moduledoc """
  Converts provider-specific events into SkillKit events.

  Each implementation handles one provider event type and may emit
  zero or more SkillKit events. The accumulator carries state needed
  across events (e.g., partial JSON for tool call inputs).
  """

  @spec to_events(t(), map()) :: {[struct()], map()}
  def to_events(event, acc)
end
