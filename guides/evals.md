# Evals

Evals are the test counterpart to skills. Where a `SKILL.md` injects
instructions into an agent, an `EVAL.md` describes behaviors the skill should
produce and the criteria for success. The eval harness loads the skill under
test into a fresh agent, sends each case's prompt, and asks an LLM judge
whether the resulting transcript meets the criteria.

`SkillKit.Eval.Case` plugs evals into ExUnit, so `mix test` runs your skill
evals alongside your unit tests.

SkillKit dogfoods its own harness: the skills under `examples/skills/` carry
colocated `EVAL.md` suites, wired up in `test/examples/skills_eval_test.exs`.
Run them against a real provider with `mix test --include eval`.

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
# run only the skill evals against a real provider
ANTHROPIC_API_KEY=... SKILL_KIT_STORAGE=file mix test --only eval
```

If your skills under test live on disk (the colocated case), the eval run needs
the `File` storage backend. SkillKit's test env defaults to in-memory storage,
so its `config/runtime.exs` switches to `SkillKit.Storage.File` when
`SKILL_KIT_STORAGE=file` is set — omit this if your evals provide skills through
whatever backend you've already configured.

Because the default test provider is the mock, pin the agent (and judge) to an
explicit provider URI so the cases hit the real API:

```elixir
use SkillKit.Eval.Case,
  dir: "skills",
  run: [
    model: "anthropic:claude-sonnet-4-20250514",
    judge_model: "anthropic:claude-sonnet-4-20250514"
  ]
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

## Caching

Evals are expensive — each is an agent run plus a judge call — so the runner
can skip a case that already passed when nothing in its *scope* has changed.
Enable it with `run: [cache: true]`:

```elixir
use SkillKit.Eval.Case, dir: "skills", run: [cache: true]
```

The scope fingerprint (`SkillKit.Eval.Cache`) covers the case text (name,
prompt, rubric, system), the agent and judge models, the source of every skill
and tool under test (file contents on disk, or the module name for module
providers), and a harness-version token bumped when scoring changes. A case
whose fingerprint matches a recorded **pass** is skipped — its result is marked
`cached: true` and no LLM is called. Failures and unknown fingerprints always
run; failures are never cached.

The cache is a term file. `cache: true` stores it under `_build/<env>/`
(ephemeral, already gitignored — a fresh CI checkout runs every eval); pass a
path string to put it elsewhere and commit it to share skips with CI:

```elixir
use SkillKit.Eval.Case, dir: "skills", run: [cache: ".skill_kit/eval_cache.bin"]
```

Because LLMs are non-deterministic, a cache hit means "this exact scope already
passed, trust it" rather than a guaranteed-identical re-run — the right
contract for an expensive suite, like a build cache. Delete the cache file to
force a full re-run.

## Running evals in CI

SkillKit's own CI (`.github/workflows/ci.yml`) runs the dogfood evals as a
separate, blocking `evals` job, and persists the result cache across runs so
only changed skills cost an API call:

```yaml
- name: Cache eval results
  uses: actions/cache@v4
  with:
    path: .skill_kit/eval_cache.bin
    # run_id never pre-exists, so the cache is re-saved every run; restore-keys
    # loads the most recent prior copy.
    key: ${{ runner.os }}-evalcache-${{ github.run_id }}
    restore-keys: ${{ runner.os }}-evalcache-

- name: Run skill evals
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    SKILL_KIT_STORAGE: file
  run: mix test test/examples/skills_eval_test.exs --only eval
```

The run is scoped to the dogfood suite file: a bare `--only eval` sweeps in
every `:eval`-tagged test in the repo, including mock-based fixtures that have
no real provider and can't pass on their own.

A plain `actions/cache` keyed on `mix.lock` (like the deps cache) will **not**
work for results: that key only changes with dependencies, and a cache is
immutable per key, so an existing entry is never re-saved. The rolling
`run_id` key above re-saves on every run.

The eval job is gated by a `RUN_EVALS` flag so any repo can opt out: set the
`RUN_EVALS` repository variable to `"false"` to skip it, or trigger a one-off
run with the workflow's `run_evals` input. It is on by default and blocking — a
failing eval fails the check.

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
