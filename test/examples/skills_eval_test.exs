defmodule SkillKit.Examples.SkillsEvalTest do
  @moduledoc """
  Dogfoods the eval harness against the skills shipped in `examples/skills`.

  Each `EVAL.md` sits next to its `SKILL.md`, so the skill under test loads
  automatically with no frontmatter. These tests drive a real agent and an LLM
  judge, so they are tagged `:eval` and excluded from the default suite — opt in
  with a configured provider:

      LLM_PROVIDER=anthropic mix test --include eval

  `cache: true` records passes under `_build/` so re-runs skip cases whose skill
  source, prompt, rubric, and models are unchanged.
  """
  use SkillKit.Eval.Case, dir: "examples/skills", run: [cache: true]
end
