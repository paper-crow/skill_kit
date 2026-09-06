defmodule SkillKit.Examples.AgentsEvalTest do
  @moduledoc """
  Dogfoods whole-agent evals against the agents shipped in `examples/agents`.

  Each `EVAL.md` sits next to an `AGENT.md`, so the eval runs that whole agent —
  its identity, skills, and sub-agents — via `SkillKit.start_agent/2`, and the
  cache keys on the agent directory's contents. Tagged `:eval`; run with:

      ANTHROPIC_API_KEY=... mix test test/examples/agents_eval_test.exs --only eval

  The model is pinned to an explicit `anthropic:` URI (the agents' `AGENT.md`
  files leave the model unset, which would otherwise fall back to the test
  mock).
  """
  use SkillKit.Eval.Case,
    dir: "examples/agents",
    run: [
      model: "anthropic://claude-sonnet-4-6",
      judge_model: "anthropic://claude-sonnet-4-6",
      cache: ".skill_kit/eval_cache.bin"
    ]
end
