defmodule SkillKit.Backend do
  @moduledoc """
  Behaviour for loading kits (bundles of skills and agent definitions).

  A backend is a data source that returns `%SkillKit.Kit{}` structs.
  SkillKit ships `SkillKit.Backend.Filesystem` for loading from disk.
  Host applications implement this behaviour for their own storage.
  """

  @callback load_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
end
