# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-09-06

### Added

- Eval cost reporting: every eval case now reports its USD cost — the agent run plus the LLM judge call, each priced at its own model via `SkillKit.LLM.Pricing`. `SkillKit.Eval.Case` prints a per-case cost line to stderr (so it's visible even on a pass, which ExUnit otherwise renders silently), and the cost appears in `SkillKit.Eval.Result.failure_message/1` for failures. `SkillKit.Eval.Result` carries the combined `:usage` and total `:cost` (`nil` when a model has no known rate, `0.0` for a cached case). New module `SkillKit.Eval.Cost`; `SkillKit.Eval.Transcript` now carries the agent's `:usage`, and `SkillKit.Eval.Judge.judge/3` returns `{verdict, usage}`.

### Changed

- Eval docs and examples now use the authority-form model URI (`anthropic://claude-sonnet-4-6`) consistently with the rest of the codebase, instead of the scheme-colon form (`anthropic:claude-sonnet-4-6`). Both resolve identically; this is a consistency fix only.

### Fixed

- Model URIs with a provider-namespaced slug (`vendor/model`) now resolve correctly: `SkillKit.LLM.get_provider_and_opts/1` combines the URI authority and path, so `openrouter://openai/gpt-4o` resolves to the model `openai/gpt-4o` instead of dropping the path and yielding `openai`. Single-segment models are unaffected.

[0.5.0]: https://github.com/paper-crow/skill_kit/releases/tag/v0.5.0

## [0.4.0] - 2026-06-20

### Added

- Anthropic prompt caching, on by default: `SkillKit.LLM.Anthropic` places two cache breakpoints per request — one covering the system prompt + tool list (the stable prefix) and a rolling one on the last user message — so repeated turns read from Anthropic's prompt cache. TTL defaults to `"5m"`; disable with `cache: false` or extend with `cache_ttl: "1h"`, set via `config :skill_kit, SkillKit.LLM.Anthropic` or per-call `stream/2` opts. Cache read/write token counts now flow through `SkillKit.Event.Usage`. New transforms live in `SkillKit.LLM.Anthropic.Encoder` (`cache_last_message/2`, `cache_system/2`).
- `SkillKit.LLM.Pricing`: derives request cost from token usage — including cache-read/write input tokens — for a given model, enabling per-call cost reporting.
- Usage and cost telemetry: the agent's stream accumulator accumulates cache token counts and emits usage+cost telemetry, forwarding `Usage` events (now carrying cache counts) to the caller.

[0.4.0]: https://github.com/paper-crow/skill_kit/releases/tag/v0.4.0

## [0.3.0] - 2026-06-20

### Added

- Per-skill model selection: a `SKILL.md` may declare `metadata.model` to run its activation sub-loop on a specific model (provider-URI string, same form as `AGENT.md`'s `model:`, including `?max_tokens=...` query params), falling back to the agent's model when unset, blank, or naming an unconfigured provider (the fallback is logged). `"model"` is now a reserved skill-metadata key. No struct, frontmatter-parser, or public-API change — `SkillKit.Agent.SkillActivation` validates and threads the resolved model into the sub-loop config, and `SkillKit.Agent.SubLoop` honors a config `:model` (defaulting to the parent agent's model, so the event sub-loop path is unaffected). The resolved model is also exposed in the `:skill_activation` hook/telemetry context.
- The agent event-stream consumer is extracted into `SkillKit.Stream` (`stream/2`) — a lazy `Enumerable` over an agent's `Delta` / `ToolCallComplete` / `AssistantMessage` / turn-end events. The `skill_kit.chat`, `skill_kit.ralph`, and `skill_kit.demo` mix tasks and the `persona_chat` example now consume it instead of each hand-rolling the same `receive` loop, and a duplicated `.env` loader collapses into `Mix.SkillKit.Dotenv`.
- Evals: skill evaluation suites expressed as markdown `EVAL.md` files. Each `##` heading is a case; its `### Prompt` section is sent to a fresh agent loaded with the skill under test, and an LLM judge scores the transcript against the case's `### Expect` rubric. When an `EVAL.md` sits next to a `SKILL.md`, that skill is loaded automatically — no frontmatter needed; optional frontmatter (`skills`, `tools`, `model`, `system`) covers non-colocated skills and overrides. `SkillKit.Eval.Case` (`use SkillKit.Eval.Case, dir: "skills"`) discovers cases at compile time and defines one ExUnit test per case — running skill evals as part of `mix test`. Generated tests are tagged `:eval` so they can be gated behind a real LLM provider (`mix test --include eval`) while the harness itself is unit-tested against the mock. New modules: `SkillKit.Eval`, `SkillKit.Eval.Case`, `SkillKit.Eval.Runner`, `SkillKit.Eval.Judge`, `SkillKit.Eval.Result`, `SkillKit.Eval.Check`, `SkillKit.Eval.Transcript`. See the [Evals guide](guides/evals.md).
- Eval result caching (`SkillKit.Eval.Cache`): `run: [cache: true]` skips cases whose scope already passed. The scope fingerprint covers the case text, the agent/judge models, the source of every skill/tool under test, and a harness-version token; a matching recorded pass is skipped with no LLM call (`Result.cached == true`), while failures and changed scopes always re-run. The cache is a term file under `_build/<env>/` by default, or a path you pass (e.g. to commit and share with CI).
- Eval judging is severity-weighted: `SkillKit.Eval.Judge` always resolves to pass or fail, reserves `FAIL` for critical shortfalls (security, vulnerability, incorrect/harmful output, or a core rubric requirement unmet), and downgrades minor non-critical deviations to a `PASS` with a one-line warning. Warnings thread through `SkillKit.Eval.Check` (`:warning`) and `SkillKit.Eval.Result.warnings/1`, and `SkillKit.Eval.Case` prints them on an otherwise-silent passing eval. `Result.failure_message/1` now also renders the captured transcript — the prompt, the tools called, and the agent's response — so a failure shows the judge's verdict and the output it judged.
- `SkillKit.Eval.Case` runs eval tests against `SkillKit.Storage.File` by default (configurable with `:storage`), via a per-test `setup`, so colocated `SKILL.md` files resolve from disk even when the app is otherwise configured for in-memory storage.
- Whole-agent evals: an `EVAL.md` (or `agent:` frontmatter) can target an `AGENT.md` directory, and the runner boots that entire agent — identity, skills, sub-agents — via `SkillKit.start_agent/2` and judges its transcript, rather than loading a bare skill. A colocated `AGENT.md` is inferred automatically (`SkillKit.Eval.agent_source/1`); the cache folds the agent directory's contents into the fingerprint, and the model is overridden from `:run`/frontmatter so the eval hits a known provider.
- Evals can be colocated with the application code they exercise. `use SkillKit.Eval` enables a doctest-style `@eval` attribute (collected via `__skill_evals__/0` and discovered with `use SkillKit.Eval.Case, modules: [...]`); alternatively a `<source>.EVAL.md` sidecar next to `<source>.ex` infers its subject module from that file (an explicit `module:` frontmatter key also works). Either way the eval records a subject `module`, and the cache folds that module's compiled MD5 — and the MD5 of any module skill/tool provider — into the fingerprint, so changing the code an eval runs re-runs it instead of serving a stale pass. A `SkillKit.Tool` subject module is offered to the agent as a tool; a kit/skill provider is loaded as a skill.

### Changed

- Model-URI query params are no longer coerced or allowlisted in `SkillKit.LLM`. The resolver now passes them through verbatim under a single `:params` key as an opaque string map (`%{"max_tokens" => "8000"}`), and each provider picks out and coerces the params it supports — `SkillKit.LLM.Anthropic` handles `max_tokens`/`temperature`/`top_p`. This removes `String.to_atom/1` on URI input (no atom-table exhaustion from authored model strings) and keeps API-specific type knowledge in the provider where it belongs.

### Removed

- `SkillKit.LLM.Metadata` (the `skill_kit:backend:*` flat-metadata convention for per-skill LLM config). It was never wired into the activation path and is superseded by the more compact `metadata.model` provider-URI string, which carries provider, model, and generation params (`?max_tokens=…&temperature=…`) in one value.

[0.3.0]: https://github.com/paper-crow/skill_kit/releases/tag/v0.3.0

## [0.2.1] - 2026-06-08

### Fixed

- Compilation under Elixir 1.18.x on OTP 28. Compiled regexes (`~r/.../`) now hold a `#Reference` on OTP 28, which cannot be escaped into a module attribute, so any module storing a regex in an attribute failed to compile with `cannot escape #Reference`. The affected modules — `SkillKit.Webhook.Verifier.Slack`/`Github`/`Stripe` (the `@defaults` maps), `SkillKit.Kit.Local.Parser`, and `SkillKit.Scope.Validation` — now build their regexes in a private function instead. No public API or behavior change.

[0.2.1]: https://github.com/paper-crow/skill_kit/releases/tag/v0.2.1

## [0.2.0] - 2026-06-07

### Added

- Vision support in user messages: `SkillKit.Types.UserMessage` content may now be a list of content blocks (text and images), not just a string.
- Image and content-block lists in tool results: `SkillKit.Types.ToolResult` accepts structured content, dispatched correctly through the tool pipeline.

### Changed

- Skills now default `:tool` to `nil` (knowledge-only) instead of `SkillKit.Tools.Shell`. A tool-less skill injects its body without exposing an executable tool to the model; previously any tool-less skill silently granted bash access on activation. A tool is now opt-in via the `SkillKit.Kit` macro or explicit struct construction. The catalog treats `nil`-tool skills as first-class in the `activate_skill` enum.

[0.2.0]: https://github.com/paper-crow/skill_kit/releases/tag/v0.2.0

## [0.1.0] - 2026-06-07

Initial public release.

### Added

- Agent supervision tree (`SkillKit.start_agent/2`) with Registry, Catalog, and Core (Mailbox → Server → SubagentSupervisor).
- Skill domain model with frontmatter parsing, local kit loading, and provider aggregation via `SkillKit.Catalog`.
- Tool behaviour (`SkillKit.Tool`) with shell execution, hooks, and a tool runner pipeline.
- Authorization API with pluggable `SkillKit.AuthorizationProvider` and scope matching.
- LLM provider abstraction (`SkillKit.LLM`) with an Anthropic implementation and streaming events.
- Conversation persistence with pluggable stores (filesystem, in-memory) via storage abstraction.
- Webhook adapter with HMAC/Stripe/Slack/GitHub signature verifiers.
- Telemetry wrappers (`SkillKit.Telemetry`).

[0.1.0]: https://github.com/paper-crow/skill_kit/releases/tag/v0.1.0
