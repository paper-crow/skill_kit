defmodule SkillKit.Kit do
  @moduledoc """
  A packaging envelope for skills and agent definitions.

  A Kit bundles related skills and agents loaded from a single source
  (directory, database, API). Backends return Kits; the system unpacks
  them to register skills and discover agent definitions.
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Skill

  @type t :: %__MODULE__{
          name: String.t(),
          skills: [Skill.t()],
          agents: [Definition.t()],
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    skills: [],
    agents: [],
    metadata: %{}
  ]
end
