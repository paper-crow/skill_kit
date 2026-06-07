# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
