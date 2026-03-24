defmodule SkillKit.Test do
  @moduledoc """
  Test helpers for SkillKit.

  Provides Mox convenience helpers for testing agents and LLM interactions.
  Provider-specific event builders live in their own modules
  (e.g., `Anthropic.Test`).

  ## Setup

      use SkillKit.Test

  This imports `SkillKit.Test` and sets up `Mox.verify_on_exit!/1`.
  """
end
