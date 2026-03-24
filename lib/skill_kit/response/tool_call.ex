defmodule SkillKit.Response.ToolCall do
  @moduledoc """
  Describes an LLM tool call response.
  """

  @type t :: %__MODULE__{name: String.t(), input: map()}

  @enforce_keys [:name, :input]
  defstruct [:name, :input]
end
