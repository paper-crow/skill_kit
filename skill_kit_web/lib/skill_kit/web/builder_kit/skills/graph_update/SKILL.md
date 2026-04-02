---
name: graph_update
description: "Update a document's build graph entry with new hash, code files, or artifact paths"
---
Update fields on an existing document mapping in the build graph. Used after builds to record the new content hash, updated code file list, or paths to generated requirements and plan documents.

Required input:
- `document` — relative path to the document

Optional input (only provided fields are updated):
- `code_files` — updated array of code file paths
- `last_hash` — SHA-256 hex digest of the document content after build
- `requirements` — path to the generated requirements document
- `plan` — path to the generated implementation plan
