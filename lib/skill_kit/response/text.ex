defmodule SkillKit.Response.Text do
  @moduledoc """
  Describes an LLM text response.
  """

  @type t :: %__MODULE__{content: String.t()}

  @enforce_keys [:content]
  defstruct [:content]
end
