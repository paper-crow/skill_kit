# Evals

Evals are the test counterpart to skills. Where a `SKILL.md` injects
instructions into an agent, an `EVAL.md` describes a behavior the skill should
produce and the criteria for success. The eval harness loads the skill(s)
under test into a fresh agent, sends the eval's prompt, and asks an LLM judge
whether the resulting transcript meets the criteria.

`SkillKit.Eval.Case` plugs evals into ExUnit, so `mix test` runs your skill
evals alongside your unit tests.

## Writing an eval

An eval is a markdown file named `EVAL.md` (or `*.eval.md`). The frontmatter is
just wiring — which skill is under test and how to run it. The body holds the
test itself in two sections:

```markdown
---
name: "greets the user by name"
description: "The greeter should address the user warmly"
skills:
  - "skills/greeter"
---
## Prompt
Hi, I'm Sam

## Expect
The assistant greets the user by their name, Sam, in a warm, friendly tone.
```

| Frontmatter | Notes |
|-------------|-------|
| `name` | Required. Used as the ExUnit test name. |
| `description` | Optional human-readable summary. |
| `system` | Optional system prompt for the eval agent. |
| `model` | Optional model URI; falls back to the default provider. |
| `skills` | Skill providers under test — paths (`"skills/greeter"`) or module names (`"SkillKit.Tools.Shell"`). |
| `tools` | Tool providers, same forms as `skills`. |

| Body section | Role |
|--------------|------|
| `## Prompt` | The user message sent to the agent under test. |
| `## Expect` | The natural-language rubric the LLM judge scores against. |

Both sections are required. Headings match case-insensitively at any level
(`#`–`######`); only the exact words `Prompt` and `Expect` start a section, so
a `#`-prefixed line *inside* a section (a shell comment, say) stays part of
that section's content.

## Running evals as tests

Point `SkillKit.Eval.Case` at a directory of evals:

```elixir
defmodule MyApp.SkillEvalTest do
  use SkillKit.Eval.Case, dir: "test/evals"
end
```

This discovers every eval under `dir` at compile time and defines one test per
eval. Each test runs the eval through `SkillKit.Eval.Runner` and asserts that
all of its checks pass.

Generated tests are tagged `:eval`. Because they drive a real agent and an LLM
judge, exclude them from the default suite and opt in explicitly:

```elixir
# test_helper.exs
ExUnit.start(exclude: [:eval])
```

```bash
# run the skill evals against a configured provider
LLM_PROVIDER=anthropic mix test --include eval
```

Forward options to the runner with `:run`:

```elixir
use SkillKit.Eval.Case, dir: "test/evals", run: [timeout: 60_000]
```

## How scoring works

For each eval the runner produces a `SkillKit.Eval.Result` made of
`SkillKit.Eval.Check`s. The eval passes only when **every** check passes:

1. **Completion** — the agent produced a response (not an error or timeout).
   A run that doesn't complete fails here and is not sent to the judge.
2. **LLM judge** — `SkillKit.Eval.Judge` gives a model the user prompt, the
   tools the agent called, and its final response, and asks whether the
   transcript satisfies the `## Expect` rubric. The model emits a
   `VERDICT: PASS` / `VERDICT: FAIL` line that becomes a pass/fail check.

When a check fails, ExUnit prints the failing checks and the captured
transcript via `SkillKit.Eval.Result.failure_message/1`.

Pass `run: [judge: false]` (or `Runner.run(eval, judge: false)`) to skip the
judge — useful as a cheap smoke test that the agent responds at all without
spending judge tokens.

## Running an eval directly

The harness is plain functions, so you can run an eval outside ExUnit:

```elixir
{:ok, eval} = SkillKit.Eval.load_file("test/evals/greeting/EVAL.md")
result = SkillKit.Eval.Runner.run(eval, model: "anthropic:claude-sonnet-4-20250514")

SkillKit.Eval.Result.passed?(result)
#=> true
```

## Evals as meta-skills

Because an eval captures the *intended behavior* of a skill independently of
its prose, it doubles as a specification you can author a skill against: write
the eval first, draft the `SKILL.md`, and iterate until the eval is green —
test-driven development for skills. A generator that drafts and refines the
application skill from its eval builds directly on this harness.
