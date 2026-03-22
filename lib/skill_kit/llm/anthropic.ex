defmodule SkillKit.LLM.Anthropic do
  @moduledoc """
  Anthropic adapter for `SkillKit.LLM`.

  Thin wrapper that delegates to the standalone `Anthropic` library.
  """

  @behaviour SkillKit.LLM

  @impl true
  def stream(config, messages, opts) do
    Anthropic.stream(config, messages, opts)
  end
end
