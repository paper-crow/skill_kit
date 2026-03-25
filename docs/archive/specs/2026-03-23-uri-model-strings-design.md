# URI Model Strings Design

## Problem

Provider configuration is split across multiple places: `model:` in AGENT.md, `:provider` option in `start_agent`, `max_tokens` on the Definition struct, and credentials in app config. The Server knows about providers and max_tokens when it shouldn't. The LLM dispatch layer should own all of this.

## Design

### URI Format

```
scheme://model?key=value&key=value
```

- `scheme` — provider name (`anthropic`, `openai`, `local`)
- `model` (host) — model identifier passed to the provider API
- `query` — provider-specific opts (max_tokens, temperature, top_p)
- Bare strings (no `://`) are valid — just a model name, resolved via default provider

Examples:
```yaml
model: "anthropic://claude-sonnet-4-20250514?max_tokens=8096&temperature=0.7"
model: "openai://gpt-4o"
model: "claude-sonnet-4-20250514"
model: "claude-sonnet-4-20250514?max_tokens=4096"
```

### Provider Resolution

Single chain, no fallthrough ambiguity:

1. Model string has `://` → scheme atom looked up in `config[:providers]`
2. Model string is bare (no `://`) → `config[:default_provider]` looked up in `config[:providers]`
3. Model string is nil → same as bare

### App Config

```elixir
# Provider registry and default
config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic
  ],
  default_provider: :anthropic

# Provider-specific config
config :skill_kit, SkillKit.LLM.Anthropic,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  endpoint: "https://api.anthropic.com"
```

The `providers` keyword list maps scheme atoms to modules. The `default_provider` atom is looked up in `providers` when the model string has no scheme. Each provider module has its own config key for credentials and settings.

### SkillKit.LLM.stream/2

The single dispatch point. Owns all provider resolution.

```elixir
def stream(messages, opts) do
  {model_string, opts} = Keyword.pop(opts, :model)

  case resolve(model_string) do
    {:ok, provider, config, model_opts} ->
      merged = Keyword.merge(model_opts, opts)
      provider.stream(config, messages, merged)

    {:error, _} = err ->
      err
  end
end
```

Where `resolve/1`:
- Parses the model string (URI or bare)
- If URI: converts scheme to atom, looks up in `config[:providers]`
- If bare/nil: looks up `config[:default_provider]` in `config[:providers]`
- Reads provider-specific config from `Application.get_env(:skill_kit, provider_module, [])`
- Returns `{:ok, provider_module, provider_config, model_opts}`

`model_opts` are the extracted query params (max_tokens, temperature, etc.) merged with `[model: model_name]`. Caller opts (system, tools) take precedence via `Keyword.merge(model_opts, opts)`.

### URI Parsing

Private function in `SkillKit.LLM`. Uses `URI.parse/1`:

```elixir
defp parse_model_uri(nil), do: {:ok, nil, []}

defp parse_model_uri(model) when is_binary(model) do
  model
  |> URI.parse()
  |> parse_model_uri()
end

defp parse_model_uri(%URI{scheme: nil} = uri) do
  default_key = Keyword.get(llm_config(), :default_provider, :anthropic)
  parse_model_uri(%{uri | scheme: to_string(default_key)})
end

defp parse_model_uri(%URI{host: nil, path: path} = uri) when is_binary(path) do
  parse_model_uri(%{uri | host: path, path: nil})
end

defp parse_model_uri(%URI{scheme: scheme, host: model_name, query: query}) do
  with {:ok, mod} <- get_provider(scheme) do
    opts = parse_query_params(query) ++ [model: model_name]
    {:ok, mod, opts}
  end
end

def get_provider(name) when is_binary(name) do
  name
  |> String.to_existing_atom()
  |> get_provider()
end

def get_provider(name) when is_atom(name) do
  case Keyword.fetch(providers(), name) do
    {:ok, mod} ->
      {:ok, mod}

    :error ->
      {:error, {:unknown_provider, name}}
  end
end
```

Bare strings are normalized: `"claude-sonnet-4-20250514?max_tokens=4096"` → fill in default scheme, move `path` to `host`, recurse into the same URI clause. One code path handles all cases.

Providers and defaults are read from config:

```elixir
defp llm_config do
  Application.get_env(:skill_kit, __MODULE__, [])
end

defp providers do
  Keyword.get(llm_config(), :providers, [anthropic: __MODULE__.Anthropic])
end

defp default_provider do
  key = Keyword.get(llm_config(), :default_provider, :anthropic)
  Keyword.fetch!(providers(), key)
end
```

Query params are type-coerced safely via `Integer.parse`/`Float.parse`. Malformed values pass through as strings.

### Provider Credential Resolution

Each provider reads its own config. The LLM module passes it through:

```elixir
config = Application.get_env(:skill_kit, provider_module, [])
provider_module.stream(config, messages, opts)
```

The Anthropic adapter uses the config directly:

```elixir
def stream(config, messages, opts) do
  api_key = Keyword.get(config, :api_key) || System.get_env("ANTHROPIC_API_KEY")
  endpoint = Keyword.get(config, :endpoint, @default_endpoint)
  client = Anthropic.Client.new(api_key: api_key, endpoint: endpoint)
  # ... encode and stream
end
```

Priority: explicit config → env var fallback. `Client.new/1` still enforces `:api_key` — the adapter guarantees it's present.

### Server Simplification

Server loses ALL provider knowledge. No `:provider` in state, opts, or passthrough.

```elixir
defp stream(state, tools) do
  SkillKit.LLM.stream(state.messages,
    model: state.definition.model,
    system: state.definition.system_prompt,
    tools: tools
  )
end
```

**Removed from Server struct:** `:provider` field
**Removed from Agent.init:** provider extraction and passthrough to server_opts
**Removed from SkillKit.start_agent:** `:provider` option
**Removed from SkillKit.start_subagent:** provider propagation

### Definition Simplification

**Removed fields:** `max_tokens`
**Unchanged:** `model` stores the raw string from AGENT.md (URI or bare)

### Subagent Provider

Subagents resolve their own provider from their own `model:` field. No inheritance from parent. In tests, the default provider is the Mock (via test config), so subagents automatically use it too.

### Testing Strategy

Tests work via app config:

```elixir
# config/test.exs
config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic,
    mock: SkillKit.LLM.Mock
  ],
  default_provider: :mock
```

All agents with bare model strings (or nil) use the Mock. Agents with `model: "anthropic://..."` use the real adapter. `set_mox_global` handles cross-process access.

Tests can also use `model: "mock://test-model"` to be explicit.

## Scope

### In scope
- `parse_model_uri/1` and `resolve/1` private functions in `SkillKit.LLM`
- `SkillKit.LLM.stream/2` refactor
- Provider config: `config :skill_kit, SkillKit.LLM, default_module`
- Provider config: `config :skill_kit, ProviderModule, [opts]`
- Anthropic adapter rewrite (self-resolving credentials from config)
- Server: remove `:provider` from state, extract `stream/2` helper
- Definition: remove `max_tokens`
- Agent.init: remove provider passthrough
- start_agent: remove `:provider` option
- start_subagent: remove provider propagation
- Query param type coercion (safe parsing)
- Add `config/test.exs` with Mock default
- Update example AGENT.md files

### Out of scope
- OpenAI or other provider implementations
- `config/config.exs` and `config/test.exs` for default setup
- Model aliasing
- Provider-specific query param validation

### Breaking Changes
- `:provider` option removed from `start_agent/2`
- `Definition.max_tokens` removed
- `Server.provider` field removed
- `LLM.default_provider/0` signature changes
- Tests that pass `provider: {Mock, []}` must use config default instead

## Testing

- **Unit**: `parse_model_uri/1` — full URI, bare string, bare string with query params, nil, unknown scheme, query coercion
- **Unit**: `resolve/1` — URI provider, bare string default, config lookup
- **Unit**: Anthropic adapter credential chain (config → env var)
- **Unit**: Server `stream/2` helper passes model and system prompt
- **Integration**: Agent with URI model in AGENT.md
- **Backward compat**: Agent with bare model string uses default provider
- **Test config**: Mock provider via `config/test.exs`
