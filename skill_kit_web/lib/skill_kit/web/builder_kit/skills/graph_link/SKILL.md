---
name: graph_link
description: "Link a document to code files in the build graph"
---
Add or update a document-to-code mapping in the build graph. If the document already has a mapping, the code files are merged (deduplicated).

Required input:
- `document` — relative path to the document (e.g., "features/auth.md")
- `code_files` — array of code file paths relative to project root (e.g., ["lib/my_app/auth.ex"])
