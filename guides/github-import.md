# GitHub Skill Import

`SkillKit.Kit.GitHub` is a provider that imports skills from GitHub repositories
at runtime. Repos are downloaded as tarballs, cached to disk, and loaded via
`Kit.Local` — the same parsing used for local skill directories.

The provider ships built-in skills (`github:import`, `github:list`,
`github:remove`) so agents can discover and pull skills mid-conversation
without restarting.

---

## Configuration

Add `Kit.GitHub` alongside your other providers:

```elixir
{:ok, agent} = SkillKit.start_agent("agents/neve",
  skills: [
    {SkillKit.Kit.Local, dir: "./skills"},
    {SkillKit.Kit.GitHub,
      allowed_sources: ["paper-crow/*", "community/tools"],
      api_token: {:env, "GITHUB_TOKEN"},
      cache_dir: "/tmp/skill_kit/github"
    }
  ],
  caller: self()
)
```

All options are optional:

| Option | Default | Description |
|--------|---------|-------------|
| `allowed_sources` | `"*"` | Which repos can be imported (see [Allowed Sources](#allowed-sources)) |
| `api_token` | `nil` | GitHub token for private repos and higher rate limits |
| `cache_dir` | System temp dir | Where downloaded repos are stored on disk |

### Token resolution

The `api_token` option accepts three forms:

```elixir
api_token: "ghp_abc123"                # string literal
api_token: {:env, "GITHUB_TOKEN"}      # resolved from environment at call time
api_token: nil                         # unauthenticated (public repos only, 60 req/hr)
```

---

## Reference Format

Repositories are referenced as strings in the format `owner/repo[/path][@ref]`:

```
owner/repo              — default branch, root directory
owner/repo@v1.0         — tagged release
owner/repo@main         — specific branch
owner/repo@abc123       — commit SHA
owner/repo/path@main    — subdirectory within a repo
```

The referenced directory must follow the standard kit layout:

```
skills/
  summarize/SKILL.md
  translate/SKILL.md
agents/
  helper.md             (optional)
AGENT.md                (optional)
```

---

## Built-in Skills

When `Kit.GitHub` is configured as a provider, three skills are automatically
available to the agent:

### `github:import`

Downloads and caches a repository, making its skills immediately available.

```
source: "paper-crow/nlp-skills@v2.0"
```

On success, returns a confirmation listing the discovered skills:

```
Imported paper-crow/nlp-skills@v2.0 — 3 skill(s): nlp:summarize, nlp:translate, nlp:classify
```

If the repo is already cached, the download is skipped:

```
paper-crow/nlp-skills@v2.0 already cached. Skills are available.
```

### `github:list`

Lists all currently imported repositories and their skills. No arguments.

```
Imported repositories:
- paper-crow/nlp-skills@v2.0: nlp:summarize, nlp:translate, nlp:classify
- community/web-tools: web:scrape, web:search
```

### `github:remove`

Removes a cached repository from disk.

```
source: "paper-crow/nlp-skills@v2.0"
```

---

## Allowed Sources

The `allowed_sources` option controls which repos can be imported. Three
pattern forms are supported:

| Pattern | Matches |
|---------|---------|
| `"*"` | Any repository |
| `"owner/*"` | Any repository under `owner` |
| `"owner/repo"` | Exact repository match |

Pass a single string or a list:

```elixir
# Single pattern
allowed_sources: "paper-crow/*"

# Multiple patterns
allowed_sources: ["paper-crow/*", "community/tools", "my-org/*"]

# Allow everything (default)
allowed_sources: "*"
```

If an agent attempts to import a repo that doesn't match, the import fails
with a clear error message.

---

## Cache Behaviour

Downloaded repos are extracted to `{cache_dir}/{owner}/{repo}/{ref}/` on disk.
The cache persists across agent restarts.

- **Cache hit:** If the directory exists, the download is skipped.
- **Default ref:** When no `@ref` is specified, the cache key uses `"default"`. Importing the same repo with an explicit ref creates a separate entry.
- **Invalidation:** Call `github:remove` then `github:import` again. There is no automatic TTL or expiration.
- **Visibility:** The Catalog's "always fresh" model means newly imported repos appear on the very next query — no restart or cache flush needed.

---

## How It Works

`Kit.GitHub` implements both `SkillKit.Kit.Provider` and `SkillKit.Tool`.

As a **provider**, `list_kits/1` scans the cache directory on every call and
delegates to `Kit.Local` for parsing each cached repo. The built-in `"github"`
kit (containing the import/list/remove skills) is always prepended.

As a **tool**, `execute/1` dispatches to the appropriate skill handler. The
import flow is:

1. Parse the reference string (`Ref.parse/1`)
2. Validate against `allowed_sources` (`Ref.allowed?/2`)
3. Check if already cached (`Cache.exists?/2`)
4. Download tarball from GitHub API (`Client.download_tarball/2`)
5. Extract to cache directory, stripping GitHub's top-level prefix (`Cache.extract/3`)
6. Delegate to `Kit.Local` for skill discovery

Provider config (`allowed_sources`, `api_token`, `cache_dir`) flows through
each skill's `:metadata` field so it's available at execution time without
any shared state.

### Modules

| Module | Responsibility |
|--------|---------------|
| `Kit.GitHub` | Provider + Tool behaviours, orchestration |
| `Kit.GitHub.Ref` | Reference string parsing, allowed sources matching |
| `Kit.GitHub.Client` | HTTP client (Req) for GitHub tarball API |
| `Kit.GitHub.Cache` | Disk cache — extract, scan, remove |

---

## Security

Imported skills are subject to the same authorization as local skills.
The agent's `SkillKit.Scope` filters what imported skills can do — if an
imported skill requires a scope the agent doesn't have, it won't be visible.

The `allowed_sources` config is the trust boundary: it determines which
repositories an agent can import from. With `"*"`, any public repo (or private
repo with a token) can be imported. Use specific patterns to restrict this.
