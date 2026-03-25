defmodule SkillKit.Kit.Provider do
  @moduledoc """
  Behaviour for skill kit providers.

  Host applications implement this behaviour for their own storage.
  """

  @callback load_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
  @callback list_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
  @callback get_kit(config :: keyword(), name :: String.t()) ::
              {:ok, SkillKit.Kit.t()} | {:error, :not_found}

  @optional_callbacks [load_kits: 1, list_kits: 1, get_kit: 2]
end
