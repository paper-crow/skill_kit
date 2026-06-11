# Evals

Evals are the test counterpart to skills. Where a `SKILL.md` injects
instructions into an agent, an `EVAL.md` describes behaviors the skill should
produce and the criteria for success. The eval harness loads the skill under
test into a fresh agent, sends each case's prompt, and asks an LLM judge
whether the resulting transcript meets the criteria.

`SkillKit.Eval.Case` plugs evals into ExUnit, so `mix test` runs your skill
evals alongside your unit tests.

## Writing an eval

An `EVAL.md` is a *suite* of cases. Each `##` heading is one case (its text is
the case name); under it, a `### Prompt` section is the message sent to the
agent and a `### Expect` section is the rubric the LLM judge scores against.

When the `EVAL.md` lives next to the `SKILL.md` it tests, that's all you need —
no frontmatter:

```markdown
skills/greeter/
  SKILL.md
  EVAL.md
```

```markdown
## greets the user by name
### Prompt
Hi, I'm Sam

### Expect
The assistant greets the user by their name in a warm, friendly tone.

## handles a missing name
### Prompt
Hello there

### Expect
The assistant greets politely without inventing a name.
```

Headings named `Prompt` / `Expect` (case-insensitive, any level) are section
markers; every other `##` heading starts a new case. Other heading levels
inside a section stay part of its content, so a `### Step 1` inside a prompt is
just prompt text.

### Optional frontmatter

To test a skill that isn't colocated, or to add tools or pin a model, use
frontmatter — every field is optional:

```markdown
---
skills:
  - "skills/greeter"
tools:
  - "SkillKit.Tools.Shell"
model: "anthropic:claude-sonnet-4-20250514"
system: "You are being evaluated."
---
## greets the user by name
...
```

| Field | Notes |
|-------|-------|
| `skills` | Skill providers under test — paths (`"skills/greeter"`) or module names (`"SkillKit.Tools.Shell"`). Overrides the colocated `SKILL.md`. |
| `tools` | Tool providers, same forms as `skills`. |
| `model` | Model URI for the eval agent; falls back to the default provider. |
| `system` | System prompt for the eval agent. |

The skill under test resolves in this order: explicit `skills:` frontmatter, else
a `SKILL.md` sitting next to the `EVAL.md`, else nothing.

## Running evals as tests

Point `SkillKit.Eval.Case` at a directory of evals:

```elixir
defmodule MyApp.SkillEvalTest do
  use SkillKit.Eval.Case, dir: "skills"
end
```

This discovers every case under `dir` at compile time and defines one test per
case. Test names are qualified by the eval file's directory (e.g.
`"greeter: greets the user by name"`) so cases from different files don't
collide. Each test runs the case through `SkillKit.Eval.Runner` and asserts
that all of its checks pass.

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
use SkillKit.Eval.Case, dir: "skills", run: [timeout: 60_000]
```

## How scoring works

For each case the runner produces a `SkillKit.Eval.Result` made of
`SkillKit.Eval.Check`s. The case passes only when **every** check passes:

1. **Completion** — the agent produced a response (not an error or timeout).
   A run that doesn't complete fails here and is not sent to the judge.
2. **LLM judge** — `SkillKit.Eval.Judge` gives a model the user prompt, the
   tools the agent called, and its final response, and asks whether the
   transcript satisfies the `## Expect` rubric. The model emits a
   `VERDICT: PASS` / `VERDICT: FAIL` line that becomes a pass/fail check.

When a check fails, ExUnit prints the failing checks and the captured
transcript via `SkillKit.Eval.Result.failure_message/1`. Pass
`run: [judge: false]` to skip the judge — a cheap smoke test that the agent
responds at all without spending judge tokens.

## Running an eval directly

The harness is plain functions, so you can run a case outside ExUnit:

```elixir
{:ok, [eval | _]} = SkillKit.Eval.load_file("skills/greeter/EVAL.md")
result = SkillKit.Eval.Runner.run(eval, model: "anthropic:claude-sonnet-4-20250514")

SkillKit.Eval.Result.passed?(result)
#=> true
```

## Evals as meta-skills

Because an eval captures the *intended behavior* of a skill independently of
its prose, it doubles as a specification you can author a skill against: write
the eval first, draft the `SKILL.md` next to it, and iterate until the eval is
green — test-driven development for skills. A generator that drafts and refines
the application skill from its eval builds directly on this harness.
