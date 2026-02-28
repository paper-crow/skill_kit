defmodule SkillKit.Skill do
  @moduledoc """
  The minimal skill struct for Phase 1 of SkillKit.

  A `%SkillKit.Skill{}` represents a registered skill in the SkillKit registry.
  In Phase 1, the struct carries only the fields needed for registry operations:
  `:name` (the fully-qualified `"namespace:skill_name"` identifier) and
  `:namespace` (the namespace segment extracted from the name).

  ## Phase Roadmap

  - **Phase 1** (current): Minimal struct with `:name` and `:namespace` only.
    Validation of the name format happens at registration time in `SkillKit.Registry`.

  - **Phase 2**: This struct will be expanded with behaviour callbacks, frontmatter
    fields (description, parameters, tags, etc.), and file path tracking for
    hot-reload support.

  ## Naming Convention

  Skill names follow the format `"namespace:skill_name"`, where:
  - Both segments are lowercase, starting with a letter
  - Segments may contain letters, digits, underscores, and hyphens
  - Exactly one colon separates the namespace from the skill name

  Examples: `"files:read"`, `"tools:web-search"`, `"my-org:analyze_data"`

  ## Example

      iex> %SkillKit.Skill{name: "files:read", namespace: "files"}
      %SkillKit.Skill{name: "files:read", namespace: "files"}
  """

  @type t :: %__MODULE__{
          name: String.t() | nil,
          namespace: String.t() | nil
        }

  defstruct name: nil, namespace: nil
end
