---
name: generate
description: "Execute an implementation plan to generate or update code files"
---
Read the implementation plan for a document and execute it — creating or updating code files as specified in the plan.

Input:
- `document` — path to the source document (used to find the plan file via the build graph)

For each file in the plan:
1. Read the existing file (if it exists) via build:write_code
2. Generate the updated content based on the plan
3. Write the file via build:write_code

After all files are written, update the build graph with the new content hash and code file list via build:graph_update.

Before generating code, activate `build:phoenix_conventions` for the full reference of Phoenix/LiveView patterns, project structure, and anti-patterns to avoid.
