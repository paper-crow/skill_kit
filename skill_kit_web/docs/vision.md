# Vision

## The Idea

Products start as ideas expressed in natural language. This is a writing environment where that natural language *is* the source of truth — not code, not tickets, not wireframes. You describe what you're building, chat with an agent to clarify and structure your thinking, and the system handles everything downstream.

Application code is an artifact. It's produced by an agent pipeline that takes your documents through a best-practice product development lifecycle: from freeform writing to structured PRDs, requirements, test plans, and validated implementations. The code never deviates from what the documents describe because the documents are what generate it.

## How It Works

### Write, Don't Build

The interface is a zen writing environment. Natural language and conversation. No IDE, no dashboards, no context switching between tools. You write about what your product does, who it's for, and why it matters. The agent helps you think clearly — asking questions, surfacing gaps, structuring your prose into progressively more precise requirements.

### Documents Flow Downstream

A document doesn't sit idle after it's written. It enters a pipeline:

1. **Freeform writing** — describe what you're building in your own words
2. **Structured requirements** — the agent helps shape prose into PRDs, specs, and acceptance criteria
3. **Code generation** — an agent pipeline produces application code as an artifact of the requirements
4. **Validation** — continuous checks ensure the running product matches what the documents describe
5. **Course correction** — when the product drifts, the system flags it and brings you back to the document layer to decide how to resolve it

### Artifacts Beyond Code

The same documents that drive code generation can produce other artifacts:

- **Marketing content** — blog posts, landing page copy, social posts, derived from the natural flow of describing what you're building and why
- **Documentation** — user-facing docs are a refinement of the same source material, not a separate writing effort
- **Changelogs and updates** — as documents evolve and new code is generated, release notes write themselves

### Signals Flow Back In

The writing environment isn't isolated from the running product. External signals feed back into your workspace as context:

- **Error reporting** (AppSignal, Sentry) — production errors surface alongside the documents that defined the behavior
- **Analytics** — usage patterns inform which documents need attention
- **User feedback** — email, support tickets, survey responses appear as input to your next writing session
- **Social signals** — mentions, reviews, community discussions

The agent can synthesize these signals: "users are repeatedly hitting this edge case in the feature described in `docs/task-management.md`" — and you address it where you'd address anything else, in the document.

## Design Principles

### Natural Language First

Every interaction starts with writing or conversation. The system meets users where they think — in words, not syntax. Technical and non-technical contributors work in the same environment.

### Documents as Source of Truth

Code is derived, documents are primary. This inverts the typical relationship where docs are an afterthought that drifts from reality. Here, reality is generated from the docs.

### Zen Interface

The complexity of product development — CI, testing, deployment, monitoring — is abstracted behind a calm writing surface. The system does the orchestration. You do the thinking.

### Closed Loop

Write → generate → validate → observe → write. The product lifecycle is a feedback loop that starts and ends in the same place: your documents.

## Architecture

The system is a Phoenix package that mounts into any Phoenix application. The editor, agent integration, and document pipeline ship as library code — the host app provides the endpoint, database, and PubSub.

SkillKit is the runtime layer. The agent that helps you write requirements and the agents that run inside the generated application share the same primitives: Kits, Skills, Tools, and the agent supervision tree. The system that builds the product *is* the product's runtime.

## Current State

The foundation is built:

- Document editor with tree navigation, deep links, and section anchors
- Agent chat with streaming and document-aware context
- Inline threads — select text, discuss with the agent in-place
- Diff blocks with accept/reject for agent-proposed changes
- DocumentKit skills for the agent to read and navigate documents

## Roadmap

### Near Term
- BuilderKit — code generation pipeline from structured documents
- Hot-reload of generated modules into the running application
- Requirement extraction and structuring from freeform documents
- Validation pipeline — continuous checks that code matches requirements

### Medium Term
- Multi-document workspaces with cross-references and dependency tracking
- Marketing artifact generation from product documents
- Signal integrations — error reporting, analytics, user feedback

### Long Term
- Full product lifecycle in a single interface
- Team collaboration on shared document workspaces
- Self-improving pipelines that learn from validation failures
