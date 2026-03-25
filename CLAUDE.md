# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

SkillKit is an Elixir library for building composable LLM agent systems with skills, tools, and subagent delegation. It is a library (no `:mod` in `application/0`), not a Phoenix app or umbrella project.

## Commands

- `mix precommit` — full validation pipeline: compile (--warnings-as-errors), deps.unlock --unused, format, credo --strict, test. Run before marking work complete.
- `mix test path/to/file_test.exs:42` — run a single test by line number
- `mix credo --strict` — lint
- `mix dialyzer` — type checking (slow; run only when asked or for type-related changes)

## Code Style

These rules override Elixir defaults:

- **No alias shortcuts.** Alias each module individually: `alias Foo.Bar.Baz` not `alias Foo.Bar.{Baz, Qux}`.
- **Never pipe into a single function** or into `case`/`if`/`with`. Pipes require 2+ steps; otherwise use direct calls.
- **Never inline multiline expressions** into `case`/`with`/`if` clauses. Extract to a private helper function.
- **Prefer capture syntax (`&`)** over `fn` for simple expressions: `Enum.map(list, &String.upcase/1)`.
- **Use recursive function heads** to normalize data into canonical form before the main logic clause.

## Git

Conventional commits: `type(scope): message` (e.g., `feat:`, `fix:`, `refactor:`, `test:`, `docs:`).

## Architecture

- **Agent supervision tree:** `SkillKit.start_agent/2` spawns a Supervisor containing Registry, Catalog (provider aggregation, authorization, tool definitions), and Core (rest_for_one: Mailbox -> Server -> SubagentSupervisor).
- **Provider config:** Default provider set in `config/config.exs` (`:anthropic`), overridden to `:mock` in test via `config/test.exs`.
- **Handler behaviour:** `SkillKit.Handler.Behaviour` defines how skills execute. `Shell` handler runs OS commands via Port.

## Environment

`ANTHROPIC_API_KEY` environment variable required for LLM calls (loaded from `.env` in dev).
