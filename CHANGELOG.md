# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Evals: skill evaluation cases expressed as markdown `EVAL.md` files. An eval declares the skill(s) under test, a prompt, deterministic `expect` checks (response substrings, forbidden substrings, required tool calls), and an optional LLM-judge rubric (the markdown body). `SkillKit.Eval.Case` (`use SkillKit.Eval.Case, dir: "test/evals"`) discovers evals at compile time and defines one ExUnit test per eval — running skill evals as part of `mix test`. Generated tests are tagged `:eval` so they can be gated behind a real LLM provider (`mix test --include eval`) while the harness itself is unit-tested against the mock. New modules: `SkillKit.Eval`, `SkillKit.Eval.Case`, `SkillKit.Eval.Runner`, `SkillKit.Eval.Judge`, `SkillKit.Eval.Expectation`, `SkillKit.Eval.Result`, `SkillKit.Eval.Check`, `SkillKit.Eval.Transcript`. See the [Evals guide](guides/evals.md).

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
