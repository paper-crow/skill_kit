---
name: "dev:elixir-style"
description: "Elixir coding conventions and style guidelines"
---
Follow these Elixir conventions:

- Use pipe operator for data transformations
- Pattern match in function heads instead of conditionals
- Use `with` for multi-step operations that can fail
- Prefer `defp` over `def` for internal functions
- Use `@doc false` instead of omitting docs for public helpers
- Name boolean functions with `?` suffix
- Use atoms for internal state, strings for external boundaries
