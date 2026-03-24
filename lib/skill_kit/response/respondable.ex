defprotocol SkillKit.Response.Respondable do
  @moduledoc """
  Converts a response type struct into what `SkillKit.LLM.stream/2` would return.
  """

  @spec to_stream(t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def to_stream(response)
end
