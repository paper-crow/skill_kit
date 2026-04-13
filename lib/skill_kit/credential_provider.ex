defmodule SkillKit.CredentialProvider do
  @moduledoc """
  Behaviour for resolving credentials on behalf of tools.

  Tools call `list/2` to enumerate the credential keys available to an
  agent, and `fetch/3` to resolve a single key to a value. Implementations
  are responsible for scope-based policy — the agent struct (which carries
  the scope) is passed to every call.

  Configure a provider in application config:

      config :skill_kit, credential_provider: MyApp.Credentials

  If unset, this module itself is used as a null provider: `list/2` returns
  `[]` and `fetch/3` returns `{:ok, nil}` for every call. Tools that depend
  on credentials (currently `SkillKit.Tools.Shell`) will run with no
  credentials exposed until a real provider is configured.
  """

  @type agent :: SkillKit.Agent.t()
  @type key :: String.t()

  @callback list(tool :: module, agent) :: [key]

  @callback fetch(tool :: module, agent, key) ::
              {:ok, String.t() | nil} | :error

  # Default (null) implementation. Apps override by configuring a different
  # module in :skill_kit, :credential_provider.

  @doc false
  def list(_tool, _agent), do: []

  @doc false
  def fetch(_tool, _agent, _key), do: {:ok, nil}
end
