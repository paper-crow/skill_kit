defmodule SkillKit.Examples.SkillsEvalTest do
  @moduledoc """
  Dogfoods the eval harness against the skills shipped in `examples/skills`.

  Each `EVAL.md` sits next to its `SKILL.md`, so the skill under test loads
  automatically with no frontmatter. These tests drive a real agent and an LLM
  judge against Anthropic (`ANTHROPIC_API_KEY` required), so they are tagged
  `:eval` and excluded from the default suite. Run them on their own with:

      ANTHROPIC_API_KEY=... mix test test/examples/skills_eval_test.exs --only eval

  The agent and judge models are pinned to an explicit `anthropic:` URI so the
  cases hit the real provider rather than the test mock. `SkillKit.Eval.Case`
  swaps in `File` storage for the duration of these tests (the test env defaults
  to in-memory storage) so the colocated `SKILL.md` files resolve from disk.

  Passes are recorded in `.skill_kit/eval_cache.bin`; re-runs skip any case whose
  skill source, prompt, rubric, and models are unchanged. CI persists that file
  via the GitHub Actions cache, so only changed skills pay for an API call.
  """
  use SkillKit.Eval.Case,
    dir: "examples/skills",
    run: [
      model: "anthropic://claude-sonnet-4-6",
      judge_model: "anthropic://claude-sonnet-4-6",
      cache: ".skill_kit/eval_cache.bin"
    ]
end
