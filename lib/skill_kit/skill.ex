defmodule SkillKit.Skill do
  @moduledoc """
  Pure data struct representing a registered skill in SkillKit.

  `SkillKit.Skill` is a plain Elixir struct that carries all identity,
  execution, and hook configuration for a skill. Execution is delegated
  to the module named in `:executor` (default: `SkillKit.Executor.Shell`).

  ## Struct Fields

  | Field             | Type               | Default                    | Description                                  |
  |-------------------|--------------------|----------------------------|----------------------------------------------|
  | `:name`           | `String.t() \| nil` | `nil`                      | Fully-qualified `"namespace:skill_name"`     |
  | `:namespace`      | `String.t() \| nil` | `nil`                      | Namespace segment extracted from name        |
  | `:description`    | `String.t() \| nil` | `nil`                      | Human-readable description                   |
  | `:body`           | `String.t() \| nil` | `nil`                      | Skill body / prompt template                 |
  | `:location`       | `String.t() \| nil` | `nil`                      | File path or source location for this skill  |
  | `:required_scope` | `[String.t()]`      | `[]`                       | Scopes required to call this skill           |
  | `:executor`       | `module()`          | `SkillKit.Executor.Shell`  | Module responsible for executing the skill   |
  | `:hooks`          | `[SkillKit.Hook.t()]` | `[]`                     | Lifecycle hooks attached to this skill       |

  ## Naming Convention

  Skill names follow the format `"namespace:skill_name"`, where:
  - Both segments are lowercase, starting with a letter
  - Segments may contain letters, digits, underscores, and hyphens
  - Exactly one colon separates the namespace from the skill name

  Examples: `"files:read"`, `"tools:web-search"`, `"my-org:analyze_data"`
  """

  alias SkillKit.Hook

  @type t :: %__MODULE__{
          name: String.t() | nil,
          namespace: String.t() | nil,
          description: String.t() | nil,
          body: String.t() | nil,
          location: String.t() | nil,
          required_scope: [String.t()],
          executor: module(),
          hooks: [Hook.t()]
        }

  defstruct [
    :name,
    :namespace,
    :description,
    :body,
    :location,
    required_scope: [],
    executor: SkillKit.Executor.Shell,
    hooks: []
  ]
end
