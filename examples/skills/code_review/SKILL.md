---
name: "dev:code-review"
description: "Guidelines for reviewing code changes"
---
Review code against its stated contract — its `@doc`, name, and signature.
Check that:

1. It is correct for that contract — does it do what it claims?
2. It handles the inputs the contract covers (only those — not hypothetical
   inputs the contract doesn't promise to accept).
3. Its functions and variables are clearly named.
4. The important paths are tested.

Raise a finding only when the code is actually wrong, unclear, or untested for
its contract. Do not list "things to consider", potential improvements, or edge
cases outside the contract for code that is already correct — that is inventing
problems, not reviewing.

Format real findings as a numbered list. When the code is correct as written,
your entire response must be exactly:

LGTM
