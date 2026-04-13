---
name: requirements
description: "Generate a structured requirements document from a changed document"
---
Analyze a document that has changed and produce a structured requirements document at `.build/requirements/<doc_name>.md`.

The requirements document should contain:
- A summary of what changed and why it matters
- Functional requirements extracted from the document (numbered, testable)
- Affected code files from the build graph
- Acceptance criteria for each requirement

Input:
- `document` — path to the changed document
- `content` — current content of the document (optional — will be read via docs:read if not provided)

The skill writes the requirements file and returns its path. The user reviews this document in the editor before proceeding to the plan step.
