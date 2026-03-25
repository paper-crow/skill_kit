# SkillKit.Web — Self-Hosting AI Documentation & Application Framework

**Date:** 2026-03-24
**Status:** Draft

## Overview

SkillKit.Web is a Phoenix framework where markdown skill files (`.skill.md`) are the source of truth for an application. Each skill file maps to a route. The skill body defines what the route does — the LLM interprets or generates the implementation. There are no type annotations, adapter categories, or filename conventions. The skill describes what it wants to be.

ExDoc is used as a library for structured doc extraction — it parses beam files and returns `%ExDoc.ModuleNode{}` structs with all module docs, function docs, typespecs, and metadata. SkillKit.Web renders these through its own LiveView templates, inspired by ExDoc's design quality but fully integrated with the skill system and chat. An AI chat layer (enabled/disabled via environment variable) adds contextual assistance, skill evolution, and conversation-derived documentation improvements.

The admin interface (`_admin/`) is built with the same skill system, serving as the default dev experience — a file-routed Phoenix docs site that builds itself.

## Design Decisions

1. **One file, one route** — `path/to/name.skill.md` → `/path/to/name`
2. **Skill body is the spec** — no types, no adapters, no content-type conventions. The LLM reads the skill and figures out what to generate.
3. **Reactive codegen** — skill hash change triggers automatic `.ex` file regeneration
4. **ExDoc as library** — use ExDoc for doc extraction, own all rendering in LiveView
5. **Self-hosting admin** — the dev interface is built with the same skill system
6. **AI as enhancement, not dependency** — system is fully functional without LLM
7. **Three content layers** — ExDoc extraction, skill memory, conversation-derived knowledge
8. **Two packaging modes** — hex library for existing apps, generator for greenfield

## Skill File Format

```markdown
---
name: "getting-started"
description: "Getting started guide page"
cache:
  ttl: 3600
auth:
  required_scope: ["docs:read"]
---

This is the getting started page for SkillKit. It should render as an HTML guide
with a sidebar navigation, code examples with syntax highlighting, and a
step-by-step walkthrough of creating your first agent.

Include sections on: installation, configuration, starting an agent, sending
messages, and using skills.
```

The frontmatter carries identity, caching, and authorization. The body is the spec — it tells the LLM what to build. The framework imposes no opinion on what that is.

## File-to-Route Mapping

The filesystem path IS the route. The `.skill.md` extension is stripped:

```
.skills/
  docs/
    getting-started.skill.md       → /docs/getting-started
    architecture.skill.md          → /docs/architecture
  api/
    webhooks/
      stripe.skill.md              → /api/webhooks/stripe
      appsignal.skill.md           → /api/webhooks/appsignal
    agents.skill.md                → /api/agents
  app/
    dashboard.skill.md             → /app/dashboard
    settings.skill.md              → /app/settings
  _admin/
    docs.skill.md                  → /_admin/docs
    skills.skill.md                → /_admin/skills
    chat.skill.md                  → /_admin/chat
    codegen.skill.md               → /_admin/codegen
    conversations.skill.md         → /_admin/conversations
```

That's it. No hidden files, no filename conventions, no adapter selection logic. Directories are just organization.

## Architecture: Continuous Codegen

A `SkillKit.Web.Codegen` GenServer continuously generates Phoenix code from skills. The generated code runs at the endpoint — not a plug, not runtime interpretation. Real compiled Elixir modules, hot-reloaded into the running BEAM.

### Codegen Loop

1. **Load** — `Kit.Local` loads `.skill.md` files. `SkillIndex` tracks content hashes and TTL per skill.
2. **Trigger** — a codegen cycle fires when:
   - A skill's content hash changes (developer edited the `.skill.md`)
   - A skill's TTL expires (agent re-evaluates with accumulated context)
   - An exception occurs in generated code (triage handler feeds error back)
3. **Generate** — a SkillKit agent reads the skill body and produces a Phoenix module (controller, LiveView, etc.)
4. **Validate** — the generated code is compiled in memory. If compilation fails, the previous version stays. If compilation succeeds, tests run. If tests fail, the previous version stays.
5. **Hot-reload** — on success, `Code.purge/1` + `Code.load_binary/3` replaces the running module. The endpoint serves new code immediately, no restart.
6. **Write** — the generated `.ex` file is written to `lib/generated/`. Developer commits when satisfied.

### Self-Healing via Exception Handler

No external monitoring dependency. An Erlang logger handler catches exceptions in generated modules and signals the Codegen server with the error context (stacktrace, request params). The agent re-evaluates the skill with the error as additional context — "your generated code crashed with this, fix it." Same cycle: generate → compile → test → hot-reload.

```elixir
:logger.add_handler(:codegen_triage, SkillKit.Web.Codegen.TriageHandler, %{})
```

### Skill Lifecycle

1. **Skill is written** — developer creates/edits a `.skill.md` file describing what a route should do.
2. **Agent generates code** — the Codegen server detects the new/changed skill, spawns an agent, gets back a Phoenix module.
3. **Code is validated** — compiled in memory, tests run. Only promoted if everything passes.
4. **Endpoint serves generated code** — normal compiled Elixir, hot-reloaded into the BEAM.
5. **Agent improves over time** — on TTL cycles, the agent re-evaluates with accumulated memory and context. Better code replaces current code through the same validate → hot-reload path.
6. **Errors trigger re-evaluation** — exceptions in generated code are caught by the triage handler and fed back to the agent as context for the next generation cycle.

### SkillIndex

The Codegen server maintains a `SkillIndex` — an in-memory map of skills with their content hashes and TTL:

```elixir
%SkillIndex.Entry{
  route: "/app/hello",
  skill: %SkillKit.Skill{},
  hash: "sha256 of skill file content",
  ttl: 3600,
  generated_at: ~U[2026-03-24 10:00:00Z]
}
```

An entry is "stale" when:
- `generated_at` is nil (never generated)
- Content hash changed (skill file was edited)
- TTL expired (time for the agent to re-evaluate)

### Generated Code

**Generated files are committed to version control.** The `lib/generated/` directory is part of the repo. The `.failed/` subdirectory is safe from accidental compilation because the Elixir compiler matches only `.ex` files, not `.failed.ex`.

**Codegen pinning:** A generated file can be pinned by adding `# skill_kit:pinned` to its module attribute. Pinned files are excluded from regeneration.

**Error handling:**
1. Generated code is compiled in memory first
2. If compilation fails, write to `lib/generated/.failed/` with a `.failed.ex` extension
3. Previous working version stays in place
4. If the LLM is unreachable, keep current generated code running

### Route Registration

Generated modules are hot-reloaded into the BEAM. The Phoenix router references them directly:

```elixir
# In your Phoenix router — routes point to generated modules:
get "/_admin/dashboard", SkillKitWeb.Generated.Admin.Dashboard, :show
get "/app/hello", SkillKitWeb.Generated.App.Hello, :show
```

In dev, generated modules are hot-reloaded on every codegen cycle. In prod, the committed `.ex` files compile with the rest of the app.

## Content Pipeline

Three content sources, unified behind a common interface:

```elixir
@callback fetch(path :: String.t(), opts :: keyword()) :: {:ok, content} | {:error, reason}
@callback index(opts :: keyword()) :: {:ok, [entry]} | {:error, reason}
```

### Source 1: ExDoc as Library (`Content.ExDoc`)

- Uses ExDoc's retriever to extract structured doc data (`%ExDoc.ModuleNode{}`, `%ExDoc.FunctionNode{}`, typespecs, guides)
- ExDoc handles the hard parts: beam file parsing, typespec resolution, cross-references, deprecated flags, module grouping
- Runs at build time (or on demand in dev), stores structured nodes in ETS
- Each module/function is addressable by name
- Read-only source — content flows in, never written back directly
- SkillKit.Web owns all rendering — LiveView templates inspired by ExDoc's design but native to the skill system

### Source 2: Skill Memory (`Content.SkillMemory`)

- Each skill accumulates memory: common questions, failure patterns, improved explanations
- Stored as `.memory.md` files alongside the skill: `docs/getting-started.memory.md`
- AI writes to memory during chat interactions
- Codegen agent reads memory alongside the skill body — augments context for generation
- Has its own content hash — SkillIndex tracks combined skill+memory hash
- TTL-based: LLM periodically consolidates/prunes memory

### Source 3: Conversation-Derived Knowledge (`Content.Conversations`)

- Chat conversations stored locally (reuses SkillKit's `Conversation.Store`)
- AI periodically synthesizes patterns across conversations
- Proposes edits to skill files, new skill files, or source code `@moduledoc`/`@doc` annotations
- All proposals written to disk as uncommitted changes — developer reviews and commits
- This is the "contributing back" loop: use → chat reveals gaps → AI proposes fixes → developer commits

## Chat Component

`SkillKit.Web.ChatLive` — a mountable LiveView component, not a full page.

```elixir
<.live_component module={SkillKit.Web.ChatLive}
  id="chat"
  context={@current_skill}
  scope={@current_scope}
/>
```

- Collapsible side panel (right edge)
- Starts a SkillKit agent scoped to the current page context
- Agent sources: current skill + memory, ExDoc content index, available skills
- Messages stream via existing SkillKit event system (Delta, ToolCallStart, etc.)
- Conversation persisted per user + route via `Conversation.Store`

### Chat Capabilities (Skill-Driven)

- Explain the current page/module/function
- Generate contextualized code examples
- Run examples (if shell handler skill available)
- Propose edits to skill files, memory files, or source code docs
- Handle inbound events and explain what happened

## AI Toggle

```elixir
# config/config.exs
config :skill_kit_web,
  ai_enabled: System.get_env("SKILL_KIT_AI_ENABLED", "false") == "true"
```

**When `ai_enabled: false`:**
- `ChatLive` component doesn't mount
- Codegen server doesn't start — no LLM calls
- App runs the last-committed generated `.ex` files (normal compiled Elixir)
- Memory and conversation evolution paused

**When `ai_enabled: true`:**
- Chat panel mounts on all skill pages
- Codegen server runs continuous generation loop (TTL + hash change + error triage)
- Memory accumulation and conversation synthesis active
- Generated code improves over time without developer intervention

The system degrades gracefully. With AI off, the committed generated code runs as a normal Phoenix app.

## Self-Hosting Admin Interface

The admin interface is built with the same skill system. It's the default dev experience.

```
.skills/
  _admin/
    dashboard.skill.md             → /_admin/dashboard
    docs.skill.md                  → /_admin/docs
    skills.skill.md                → /_admin/skills
    chat.skill.md                  → /_admin/chat
    codegen.skill.md               → /_admin/codegen (diff viewer)
    conversations.skill.md         → /_admin/conversations

  # Production app skills live alongside:
  app/
    dashboard.skill.md             → /app/dashboard
  api/
    agents.skill.md                → /api/agents
```

### Dev vs Prod Topology

```
Dev mode:
  localhost:4000/              → Production routes (from skills, live-interpreted)
  localhost:4000/_admin/       → Admin/docs interface (always on in dev)

Prod mode:
  yourapp.com/                 → Production routes (compiled .ex files)
  /_admin/                     → Disabled by default (SKILL_KIT_ADMIN=true to enable)
```

### The Self-Building Loop

1. Developer opens `/_admin/` — browses docs, reads about a module
2. Opens chat — "how do I add a Stripe webhook?"
3. AI creates `.skills/api/webhooks/stripe.skill.md`
4. Next request triggers the skill pipeline, codegen post-hook generates `.ex` file
5. App immediately serves the new route in dev
6. Developer tests, iterates via chat — AI edits the skill based on feedback
7. Skill memory accumulates what worked
8. Developer reviews diffs in `/_admin/codegen`, commits when satisfied
9. The `_admin/` skills themselves improve through use — the system builds itself

## Packaging

### Core Library Modules (`lib/skill_kit/web/`)

The codegen system lives in the `skill_kit` library itself:

```
lib/skill_kit/web/
├── codegen.ex                       # GenServer: continuous codegen loop
├── codegen/
│   ├── generator.ex                 # Spawns SkillKit agent to generate Phoenix modules
│   ├── compiler.ex                  # Compiles in memory, writes to disk
│   ├── loader.ex                    # Hot-reloads via Code.purge/load_binary
│   └── triage_handler.ex           # Logger handler: catches exceptions, signals codegen
└── skill_index.ex                   # Tracks skills, hashes, TTL
```

### Example App (`examples/skill_kit_web`)

Minimal Phoenix app that starts the Codegen server:

```
examples/skill_kit_web/
├── mix.exs                          # Phoenix app, depends on skill_kit via path
├── lib/skill_kit_web/
│   ├── application.ex               # Starts Codegen as child
│   ├── endpoint.ex
│   └── router.ex                    # Routes point to generated modules
├── .skills/
│   ├── _admin/
│   │   └── dashboard.skill.md
│   └── app/
│       └── hello.skill.md
└── lib/generated/                   # Codegen output, committed to repo
```

### Phase 2: Extract to Hex Package

Once the example proves the concept, extract reusable pieces into a `skill_kit_web` hex package.

## Relationship to Existing SkillKit

| SkillKit Core | SkillKit.Web |
|---|---|
| Agent runtime | Codegen.Generator spawns agents to produce Phoenix modules |
| Kit.Local | Same — loads skills from `.skills/` directory |
| Skill struct | Same struct — web frontmatter stored in `metadata` map |
| Conversation.Store | Same, reused for chat persistence |
| Scope protocol | Same, reused for route authorization |

SkillKit.Web uses the core agent runtime to generate code. The generated code runs independently.
