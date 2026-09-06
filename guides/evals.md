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
Run them against a real provider with `mix test --only eval`.

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
model: "anthropic://claude-sonnet-4-6"
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

## Colocating evals with code

When an eval exercises **application code** — a tool module, or a skill whose
behavior runs through your modules — keep the eval next to that code. The eval
then anchors to the module, and the eval cache keys on the module's compiled
hash (`Module.module_info(:md5)`): change the code and the eval re-runs; leave
it untouched and a prior pass is reused. No dependency lists to maintain.

Two forms, both setting the eval's subject `module`:

**`@eval` attribute** — the eval lives in the module, doctest-style:

```elixir
defmodule MyApp.Greeter do
  use SkillKit.Eval

  @eval """
  ## greets the user by name
  ### Prompt
  Hi, I'm Sam
  ### Expect
  Greets the user by name.
  """
  def greet(name), do: ...
end
```

**Sidecar file** — keep the markdown in a file named after the source file. The
subject module is read from the sibling `.ex`; no frontmatter:

```
lib/my_app/
  greeter.ex          # defmodule MyApp.Greeter
  greeter.EVAL.md     # ## greets the user by name …
```

If the subject module is itself a `SkillKit.Tool` it's offered to the agent as a
tool; if it's a kit/skill provider it's loaded as a skill. Either way the
module's MD5 anchors the cache. Discover `@eval` modules with
`use SkillKit.Eval.Case, modules: [MyApp.Greeter]`; sidecars are found by
pointing `dir:` at your source tree (e.g. `dir: "lib"`). For the rare case where
the sidecar can't sit beside its `.ex`, an explicit `module:` frontmatter key
still works.

## Evaluating whole agents

To eval an agent rather than a single skill, drop an `EVAL.md` next to its
`AGENT.md`:

```
agents/researcher/
  AGENT.md
  EVAL.md
```

The runner boots the **whole agent** — its `AGENT.md` identity, skills, and
sub-agents — via `SkillKit.start_agent/2`, sends the prompt, and judges the
transcript. The eval anchors to the agent directory, so the cache keys on its
contents (`AGENT.md` + every skill under it); change anything the agent is made
of and the eval re-runs.

The colocated `AGENT.md` is inferred automatically; point elsewhere with an
`agent:` frontmatter key. The model is taken from `:run`/frontmatter (so the
eval hits a known provider) and otherwise falls back to the agent's own model.

```markdown
---
agent: "agents/researcher"
---
## cites sources
### Prompt
What logging library does this project use?
### Expect
Names the library and cites the file where it's configured.
```

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
ANTHROPIC_API_KEY=... mix test --only eval
```

Because the default test provider is the mock, pin the agent (and judge) to an
explicit provider URI so the cases hit the real API:

```elixir
use SkillKit.Eval.Case,
  dir: "skills",
  run: [
    model: "anthropic://claude-sonnet-4-6",
    judge_model: "anthropic://claude-sonnet-4-6"
  ]
```

Eval skills are loaded from real files on disk, but the test environment
defaults to in-memory storage. `SkillKit.Eval.Case` handles this for you: a
per-test `setup` swaps in `SkillKit.Storage.File` while each `:eval` test runs
(and restores the prior provider after), so colocated `SKILL.md` files resolve.
Pass `storage: false` to the macro to leave your configured provider in place,
or `storage: MyApp.Storage` to swap in a different one.

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
   transcript satisfies the `## Expect` rubric. The verdict is
   **severity-weighted** and always resolves to pass or fail:

   - `FAIL` is reserved for *critical* shortfalls — a security or safety
     problem, a vulnerability, incorrect/harmful output, or a critical failure
     to do what the rubric asks.
   - Everything else `PASS`es. When the substance is right but the transcript
     deviates in a non-critical way (different wording, optional suggestions,
     extra caveats, hypothetical edge cases), the judge passes it and attaches
     a one-line `WARNING:`. The rubric sets the bar for *substance*, not exact
     wording the agent must reproduce.

   This keeps a capable agent from failing over non-critical nitpicks while
   still hard-failing genuinely bad behavior.

When a check fails, ExUnit prints the failing checks and the captured
transcript (prompt, tools called, response) via
`SkillKit.Eval.Result.failure_message/1`. Warnings on a *passing* eval are
printed too — ExUnit shows nothing for a pass otherwise — and are available via
`SkillKit.Eval.Result.warnings/1`. Pass `run: [judge: false]` to skip the judge
— a cheap smoke test that the agent responds at all without spending judge
tokens.

## Cost

Every eval reports its USD cost to stderr — the agent run plus the judge call,
each priced at its own model — so the price of a suite is visible even when
tests pass (ExUnit prints nothing for a pass otherwise):

```
  $ greeter: greets the user by name: $0.0142
  $ greeter: handles a missing name: $0.0117
```

The figure comes from the token usage the models report, priced by
`SkillKit.LLM.Pricing`. A model with no known rate prints `cost unknown` rather
than an understated number; a cached case (see below) prints `$0.0000` since it
spent no tokens. The cost is also on `SkillKit.Eval.Result` (`:cost` and the
combined `:usage`) and appears in the failure message when a case fails.

## Caching

Evals are expensive — each is an agent run plus a judge call — so the runner
can skip a case that already passed when nothing in its *scope* has changed.
Enable it with `run: [cache: true]`:

```elixir
use SkillKit.Eval.Case, dir: "skills", run: [cache: true]
```

The scope fingerprint (`SkillKit.Eval.Cache`) covers the case text (name,
prompt, rubric, system), the agent and judge models, the source of every skill
and tool under test (file contents for path providers, the **compiled MD5** for
module providers), the subject `module`'s MD5 when the eval is colocated with
code, and a harness-version token bumped when scoring changes. A case whose
fingerprint matches a recorded **pass** is skipped — its result is marked
`cached: true` and no LLM is called. Failures and unknown fingerprints always
run; failures are never cached. Because module providers and module-anchored
evals hash compiled code, changing the application code an eval exercises
re-runs it rather than serving a stale pass.

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
result = SkillKit.Eval.Runner.run(eval, model: "anthropic://claude-sonnet-4-6")

SkillKit.Eval.Result.passed?(result)
#=> true
```

## Evals as meta-skills

Because an eval captures the *intended behavior* of a skill independently of
its prose, it doubles as a specification you can author a skill against: write
the eval first, draft the `SKILL.md` next to it, and iterate until the eval is
green — test-driven development for skills. A generator that drafts and refines
the application skill from its eval builds directly on this harness.
