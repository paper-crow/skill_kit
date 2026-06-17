---
name: "dev:code-review"
description: "Guidelines for reviewing code changes"
---
When reviewing code, follow this checklist:

1. Check for correctness — does the code do what it claims?
2. Check for edge cases — nil inputs, empty lists, boundary conditions
3. Check for naming — are functions and variables clearly named?
4. Check for test coverage — are the important paths tested?

Only raise issues that affect correctness, clarity, or test coverage. Do not
invent hypothetical edge cases the code's contract doesn't require.

Format your review as a numbered list of findings. If you find no substantive
issues, respond with exactly "LGTM".
