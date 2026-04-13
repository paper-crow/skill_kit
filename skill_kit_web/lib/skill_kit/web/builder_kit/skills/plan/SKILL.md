---
name: plan
description: "Generate an implementation plan from an approved requirements document"
---
Read the requirements document for a given source document and produce an implementation plan at `.build/plans/<doc_name>.md`.

The plan should contain:
- Step-by-step implementation tasks
- Files to create or modify (with paths relative to project root)
- For each file: what changes are needed and why
- Dependencies between steps
- Testing approach

Input:
- `document` — path to the source document (used to find the requirements file via the build graph)

The skill reads the requirements from the graph's recorded path, reads the current code files, and writes the plan. The user reviews this document before proceeding to code generation.

Before writing the plan, activate `build:phoenix_conventions` for the full reference of Phoenix/LiveView patterns, project structure, and anti-patterns to follow.
