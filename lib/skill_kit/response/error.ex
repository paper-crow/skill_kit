defmodule SkillKit.Response.Error do
  @moduledoc """
  Describes an LLM error response.
  """

  @type t :: %__MODULE__{status: integer(), message: String.t()}

  @enforce_keys [:status, :message]
  defstruct [:status, :message]
end
