# Authorization

SkillKit uses a scope-based access control system to restrict which skills a
caller may discover and activate. Authorization is a pure-function concern —
no process state, no GenServer coupling — and is safe to call from concurrent
contexts without synchronization.

## Scope Format

A scope is a two-segment string: `"namespace:action"`.

- Both segments must match `^[a-z][a-z0-9_-]*$` (lowercase ASCII, digits,
  hyphens, underscores).
- A wildcard scope `"namespace:*"` matches any action within that namespace.
- The bare string `"*"` is **not** a valid scope.
- Three-segment strings (e.g. `"a:b:c"`) are always invalid.

Valid examples: `"admin:read"`, `"skills:execute"`, `"tools:delete-all"`,
`"tools:*"`.

Use `SkillKit.Scope.valid?/1` or `SkillKit.Scope.validate/1` to check a scope
string at runtime.

## ALL-of Semantics

A skill can require multiple scopes. The caller must hold **every** required
scope — holding any subset is not enough. Within each required scope, a granted
wildcard (`"ns:*"`) satisfies any exact scope in the same namespace, but
wildcards never cross namespace boundaries (`"ski:*"` does not cover
`"skills:read"`).

## Configuring Scopes on a Skill

Set `required_scope` on the `SkillKit.Skill` struct. It defaults to `[]`, which
means the skill is public — no authorization check is performed and the provider
is never called.

```elixir
%SkillKit.Skill{
  name: "admin:purge",
  required_scope: ["admin:write", "audit:log"],
  body: "...",
  ...
}
```

## Direct Authorization

Call `Authorization.authorize/2` when you already have a flat list of granted
scope strings (e.g. decoded from a token before entering your pipeline):

```elixir
alias SkillKit.Authorization

skill = %SkillKit.Skill{required_scope: ["admin:read"]}

{:ok, ^skill}         = Authorization.authorize(skill, ["admin:read", "admin:write"])
{:error, :unauthorized} = Authorization.authorize(skill, ["tools:read"])

# wildcard grant
{:ok, ^skill} = Authorization.authorize(skill, ["admin:*"])
```

Use `Authorization.authorized?/2` when a boolean is more convenient:

```elixir
Authorization.authorized?(skill, ["admin:*"])  # => true
Authorization.authorized?(skill, [])           # => false
```

## Provider-Based Authorization

When scope resolution involves I/O (token verification, database lookup) pass a
provider module and an opaque context map to `Authorization.authorize/3`. The
provider is called only when `required_scope` is non-empty.

```elixir
{:ok, ^skill}        = Authorization.authorize(skill, MyApp.TokenProvider, %{token: "..."})
{:error, :token_expired} = Authorization.authorize(skill, MyApp.TokenProvider, %{token: "old"})
```

Provider errors pass through to the caller unchanged and are never normalized to
`:unauthorized`. Exceptions from the provider are not rescued.

## Writing an AuthorizationProvider

Implement the `SkillKit.AuthorizationProvider` behaviour. The single callback
receives the opaque context map and returns the granted scope list or an error:

```elixir
defmodule MyApp.TokenProvider do
  @behaviour SkillKit.AuthorizationProvider

  @impl SkillKit.AuthorizationProvider
  def resolve_scopes(%{token: token}) do
    case MyApp.Tokens.verify(token) do
      {:ok, claims} -> {:ok, claims["scopes"]}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

The context shape is fully opaque — the behaviour contract imposes no required
keys. Pattern-match on whatever structure your application uses and return
`{:error, reason}` for missing or invalid input.

## Catalog Integration

`SkillKit.Catalog` wraps the Registry and applies authorization automatically.

**Discovery** — `Catalog.list_skills/2` accepts a `:scopes` option. When
provided, skills whose `required_scope` is not covered are filtered out of the
result. Omitting `:scopes` returns all skills (useful for admin contexts).

```elixir
# caller holds tools:* — sees only skills covered by that grant
skills = Catalog.list_skills(server, scopes: ["tools:*"])

# no scopes option — returns everything
all = Catalog.list_skills(server)
```

**Activation** — `Catalog.activate/4` accepts the same `:scopes` option. It
calls `get_skill/3` internally, which returns `{:error, :unauthorized}` before
rendering if the caller lacks the required scopes.

```elixir
{:ok, body}              = Catalog.activate(server, "tools:search", args, scopes: ["tools:*"])
{:error, :unauthorized}  = Catalog.activate(server, "admin:purge", args, scopes: ["tools:*"])
{:error, :not_found}     = Catalog.activate(server, "missing:skill", args, scopes: ["admin:*"])
```

Note that `:not_found` and `:unauthorized` are distinct — `:not_found` is
returned exclusively by the Registry and is never produced by the authorization
layer.
