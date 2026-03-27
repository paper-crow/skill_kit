Authorization

SkillKit uses a scope-based access control system to restrict which skills a caller may discover and activate. Authorization is a pure-function concern — no process state, no GenServer coupling — and is safe to call from concurrent contexts without synchronization.




SCOPE FORMAT

A scope is a two-segment string: "namespace:action".

Both segments must match ^[a-z][a-z0-9_-]*$ (lowercase ASCII, digits, hyphens, underscores).
A wildcard scope "namespace:*" matches any action within that namespace.
The bare string "*" is not a valid scope.
Three-segment strings (e.g. "a:b:c") are always invalid.

Valid examples: "admin:read", "skills:execute", "tools:delete-all", "tools:*".

Use SkillKit.Scope.Validation.valid?/1 or SkillKit.Scope.Validation.validate/1 to check a scope string at runtime.

ALL-OF SEMANTICS

A skill can require multiple scopes. The caller must hold every required scope — holding any subset is not enough. Within each required scope, a granted wildcard ("ns:*") satisfies any exact scope in the same namespace, but wildcards never cross namespace boundaries ("ski:*" does not cover "skills:read").

CONFIGURING SCOPES ON A SKILL

Set required_scope on the SkillKit.Skill struct. It defaults to [], which means the skill is public — no authorization check is performed and the provider is never called.

%SkillKit.Skill{
  name: "admin:purge",
  required_scope: ["admin:write", "audit:log"],
  body: "...",
  ...
}
DIRECT AUTHORIZATION

Call Authorization.authorize/2 when you already have a flat list of granted scope strings (e.g. decoded from a token before entering your pipeline):

alias SkillKit.Authorization

skill = %SkillKit.Skill{required_scope: ["admin:read"]}

{:ok, ^skill}         = Authorization.authorize(skill, ["admin:read", "admin:write"])
{:error, :unauthorized} = Authorization.authorize(skill, ["tools:read"])

# wildcard grant
{:ok, ^skill} = Authorization.authorize(skill, ["admin:*"])

Use Authorization.authorized?/2 when a boolean is more convenient:

Authorization.authorized?(skill, ["admin:*"])  # => true
Authorization.authorized?(skill, [])           # => false
PROVIDER-BASED AUTHORIZATION

When scope resolution involves I/O (token verification, database lookup) pass a provider module and an opaque context map to Authorization.authorize/3. The provider is called only when required_scope is non-empty.

{:ok, ^skill}        = Authorization.authorize(skill, MyApp.TokenProvider, %{token: "..."})
{:error, :token_expired} = Authorization.authorize(skill, MyApp.TokenProvider, %{token: "old"})

Provider errors pass through to the caller unchanged and are never normalized to :unauthorized. Exceptions from the provider are not rescued.

WRITING AN AUTHORIZATIONPROVIDER

Implement the SkillKit.AuthorizationProvider behaviour. The single callback receives the opaque context map and returns the granted scope list or an error:

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

The context shape is fully opaque — the behaviour contract imposes no required keys. Pattern-match on whatever structure your application uses and return {:error, reason} for missing or invalid input.

CATALOG INTEGRATION

SkillKit.Catalog applies authorization automatically based on a scope configured at start time.

Scopes are set at start time — pass the :scope option to Catalog.start_link/1. The catalog resolves permissions once from that scope and applies them to every subsequent query.

# Start a catalog that only exposes skills covered by tools:*
{:ok, server} = Catalog.start_link(providers: [...], scope: ["tools:*"])

# Start an unrestricted catalog (admin context)
{:ok, server} = Catalog.start_link(providers: [...])

Discovery — Catalog.list_skills/1 takes no options. It returns only skills the configured scope covers (or all skills when no scope was set).

# returns only skills authorized by the scope set at start_link
skills = Catalog.list_skills(server)

Lookup — Catalog.get_skill/2 returns {:error, :unauthorized} when the configured scope does not cover the requested skill’s required_scope.

{:ok, skill}             = Catalog.get_skill(server, "tools:search")
{:error, :unauthorized}  = Catalog.get_skill(server, "admin:purge")
{:error, :not_found}     = Catalog.get_skill(server, "missing:skill")

Note that :not_found and :unauthorized are distinct — :not_found means the skill does not exist; :unauthorized means it exists but the configured scope does not cover it.