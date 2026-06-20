# Framework Change Proposal — per-skill model selection (`SKILL.md` `metadata.model`)

**Status:** proposal · 2026-06-20
**Scope:** core (`agent/skill_activation.ex`, `agent/sub_loop.ex`) — no struct changes.

## Problem

A skill activation always runs on the **parent agent's** model: `SubLoop.loop/5` streams with `model: parent_state.agent.model`. The only model boundaries SkillKit offers today are:
- the **agent** (`AGENT.md` `model:`) — one model for the agent and *all* its activated skills, and
- **sub-agents** (`tool_dispatch` → `agent_def.model || parent`) — a delegated agent can carry its own model.

There is **no per-skill lever**. A multi-step agent (e.g. a marketing pipeline: research → copy → design) wants to route a cheap/fast model to light steps (reading search results, writing copy) and a strong model to the one hard step (authoring valid, structured template code) — for both cost and quality. Restructuring every step into a sub-agent just to vary the model is heavy; per-skill model selection is the natural lever.

## Why this is a framework change (not a kit / host adapter)

The model is chosen *inside* `SkillKit.Agent.SubLoop.loop/5` from `parent_state.agent.model`. A host-side kit or adapter cannot intercept that without changing the activation/sub-loop path. Per `lib/skill_kit/AGENTS.md` ("Only if that prototype is physically impossible, write a Framework Change Proposal"), this qualifies. It **does not** modify any load-bearing struct shape.

## Design — respect the `metadata:` convention

`AGENTS.md` is explicit: *"'I could add a field to `%Skill{}`' is not a reason to add a field to `%Skill{}`. Use `metadata:`."* So a skill declares its model under frontmatter `metadata:`:

```yaml
---
name: design
description: Authors the OG template Liquid.
metadata:
  model: "anthropic://claude-sonnet-4-6?max_tokens=8000"
---
```

`Kit.build_kit_skill/4` already folds `metadata:` into `skill.metadata`, so **`skill.metadata["model"]` is parsed today** — no struct change, no build-site change. The model string uses the **same provider-URI resolution as `AGENT.md`** (`anthropic://…`, `openinfer://…`, or a bare string → default provider), because it flows into `LLM.stream(model: …)` unchanged.

`model` becomes a **reserved metadata key** for skills (document it; otherwise it is ordinary metadata).

## The change (two functions, no struct change)

**1. `SkillKit.Agent.SkillActivation.build_config/3`** — thread the resolved model into the sub-loop config:

```elixir
defp build_config(parent_state, skill, body) do
  %{
    system_append: body,
    initial_messages: fork_messages(parent_state.messages),
    sub_tools: build_sub_tools(parent_state, skill),
    sub_name: "#{parent_state.agent.name}/skill:#{skill.name}",
    error_prefix: "Skill activation error",
    model: Map.get(skill.metadata, "model", parent_state.agent.model)   # NEW
  }
end
```

**2. `SkillKit.Agent.SubLoop.loop/5`** — use the config's model, defaulting to the parent's:

```elixir
# was: model: parent_state.agent.model
model: Map.get(config, :model, parent_state.agent.model)
```

(`Map.get/3` rather than `config.model` so the optional key is safe for callers that don't set it.)

## Backward compatibility

- `SubLoop.run/2` has **two** callers: `SkillActivation` (now sets `:model`) and `agent/server.ex:183` (does not). `Map.get(config, :model, parent_state.agent.model)` keeps the `server.ex` event sub-loop on the parent model — unchanged.
- A skill **without** `metadata.model` → `Map.get(skill.metadata, "model", parent…)` returns the parent model → behavior identical to today.
- No struct, frontmatter-parser, or public-API change. Existing skills and kits are unaffected.

## Telemetry (small, recommended)

Add the resolved model to the `:skill_activation` hook context (today `%{skill:, agent_name:}`) → `%{skill:, agent_name:, model:}`, so observers/telemetry can show which model ran a skill. Optional; no behavior change.

## Tests

- **Honors `metadata.model`:** a skill with `metadata.model: "mock://x"` → activation streams with that model (assert via the LLM mock recording the `:model` opt).
- **Falls back:** a skill with no `metadata.model` → activation streams with `parent_state.agent.model`.
- **No regression on the server path:** the `server.ex:183` `SubLoop.run` caller still uses the parent model.
- **Resolution unchanged:** the model string still resolves through the existing provider-URI logic (covered by current LLM resolution tests; add one asserting a skill's `openinfer://`-style string resolves to the right provider).

## CHANGELOG

> Skills may declare `metadata.model` in `SKILL.md` to run their activation on a specific model (provider-URI string, same as `AGENT.md`); falls back to the agent's model when unset.

## Out of scope / alternatives

- **Top-level `model:` key on `SKILL.md`** (symmetry with `AGENT.md`'s top-level `model:`): would require build-site edits and revisiting the struct-vs-metadata convention. Deferred — `metadata.model` is the sanctioned, zero-build-change path.
- **Per-skill *provider* config:** unnecessary — the model string already selects the provider via its URI scheme.
- **Per-skill `max_tokens`/temperature:** ride along via the model URI query params (`?max_tokens=…&temperature=…`). The resolver passes query params through verbatim as an opaque string map under `:params`; each provider picks out and coerces the params it supports (`SkillKit.LLM.Anthropic` handles `max_tokens`/`temperature`/`top_p`). API-specific type knowledge lives in the provider, not the generic resolver.

> **Implementation note (superseding the sketch above):** the final change also (1) validates `metadata.model` against configured providers, falling back to the parent model (logged) on an unconfigured provider / blank / unset value; (2) moves model-URI query-param handling to providers as described; and (3) removes the unused `SkillKit.LLM.Metadata` (`skill_kit:backend:*`) convention, which `metadata.model` supersedes.
