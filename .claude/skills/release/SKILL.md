---
name: release
description: Cut a new SkillKit release and publish to hex.pm. Use whenever the user wants to release, ship a version, bump the version, cut a tag, or publish the package to hex — even if they don't name every step. Covers version bump, CHANGELOG, doc audit, precommit, PR to main, tagging, and hex.publish.
---

Cut a SkillKit release end to end. Releases are tagged on the **merge commit into `main`**, so feature work merges first, then `main` is tagged and published. Follow these steps in order; stop and surface anything unexpected rather than pushing through.

## 1. Survey what's shipping

```bash
mix hex.info skill_kit | head        # latest published version
git tag --sort=-v:refname | head     # local tags (releases are vX.Y.Z)
git log $(git describe --tags --abbrev=0 --match 'v*')..HEAD --oneline
```

Read the commit messages since the last `v*` tag — they determine the version and seed the changelog.

## 2. Choose the version (pre-1.0 SemVer)

SkillKit is < 1.0, so:

- Any `feat:` commit since the last tag → **minor** bump (e.g. `0.1.0` → `0.2.0`).
- Only `fix:` / `refactor:` / `docs:` / `chore:` → **patch** bump (e.g. `0.1.0` → `0.1.1`).

A behavior change shipped as a `fix:` (e.g. a changed default) still rides a minor bump if any `feat:` is present — call it out in the CHANGELOG under **Changed** so users notice. When the bump is ambiguous, ask the user.

## 3. Bump the version in both places

- `mix.exs` — the `version:` key.
- `README.md` — the install line `{:skill_kit, "~> X.Y.Z"}`.

Grep to be sure nothing else pins the old version: `grep -rn "OLD_VERSION" mix.exs README.md`.

## 4. Update CHANGELOG.md

Add a new section above the previous one, following the existing [Keep a Changelog](https://keepachangelog.com/) layout already in the file:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- User-facing description of each new feature, naming the public module/function it touches.

### Changed
- Behavior changes (renamed defaults, altered semantics) — explain the before/after so users can react.

### Fixed
- Bug fixes.

[X.Y.Z]: https://github.com/paper-crow/skill_kit/releases/tag/vX.Y.Z
```

Write entries from the user's perspective (what changed for someone depending on the library), not as raw commit subjects. Use today's date.

## 5. Audit docs for staleness

The changes in this release may have outdated prose. Check the surfaces the commits touched:

- `@type`/`@moduledoc` in changed modules (often already updated by the feature commit — verify, don't assume).
- `guides/` — especially tables describing message shapes, tool/skill defaults, or the public API.
- `README.md` examples.

Grep for terms tied to the change (old defaults, renamed concepts) and fix any doc that now describes the old behavior. This is a real step, not a formality — a release is the moment stale docs become user-visible.

## 6. Validate

```bash
mix precommit
```

Must be green (compile --warnings-as-errors, format, credo --strict, test). Fix failures before continuing.

## 7. Commit and open a PR to main

```bash
git commit -am "chore: release vX.Y.Z"
git push -u origin <branch>
gh pr create --base main --title "Release vX.Y.Z" --body "<summary + release checklist>"
```

If a PR for the branch already exists, update it with `gh pr edit <num>` instead of creating a duplicate. The PR body should summarize the changes and include a checklist (precommit, version bumped, CHANGELOG, merge, tag+publish).

**Stop here and let the user merge the PR.** Tagging and publishing happen from `main` after merge.

## 8. Tag and publish from main (after merge)

```bash
git checkout main && git pull
git tag vX.Y.Z && git push origin vX.Y.Z
mix hex.publish        # package
mix hex.publish docs   # hexdocs
```

`mix hex.publish` is **interactive and effectively irreversible** — once published a version can only be retired, not truly replaced. Confirm the version is right, then either let the user run the final `mix hex.publish` themselves (suggest `! mix hex.publish` so its prompts land in the session) or drive it only up to the confirmation prompt. Never publish without explicit go-ahead.

## 9. Confirm

Report the published version, the tag, and the hexdocs URL (`https://hexdocs.pm/skill_kit/X.Y.Z`).
