defmodule SkillKit.Hooks.Handler do
  @moduledoc """
  Behaviour for hook handler implementations.

  Each handler type (command, http, etc.) implements this behaviour.
  Handlers receive a config map (from YAML) and a context map (from
  the hook event) and return a gate decision.
  """

  @type result :: :ok | {:deny, term()} | {:pending, term()}

  @callback execute(config :: map(), context :: map()) :: result()
end
