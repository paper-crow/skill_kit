defmodule SkillKit.Test.EvalSubject do
  @moduledoc false
  # Fixture exercising the colocated `@eval` attribute: the eval lives in the
  # module it tests, so the eval cache keys on this module's compiled hash.
  use SkillKit.Eval

  @eval """
  ## greets by name
  ### Prompt
  Hi, I'm Sam
  ### Expect
  Greets the user by name.
  """
  def greet(name), do: "Hello, #{name}!"
end
