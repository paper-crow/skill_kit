defmodule SkillKit.Hook do
  @moduledoc """
  Represents a lifecycle hook that fires when skills execute commands.

  Hooks are global but lifetime-scoped: a hook defined on Skill A fires when
  any skill executes via a matching executor. When the defining skill is
  unregistered, its hooks are removed.

  ## Fields

  | Field      | Type                  | Description                                          |
  |------------|-----------------------|------------------------------------------------------|
  | `:phase`   | `:pre \\| :post`       | When the hook fires relative to execution            |
  | `:matcher` | `Regex.t()`           | Regex matched against the executor name (e.g. "Shell") |
  | `:handler` | `function \\| mfa`     | Logic to run — anonymous function or `{mod, fun, args}` |
  """

  @type handler :: (map() -> any()) | {module(), atom(), list()}

  @type t :: %__MODULE__{
          phase: :pre | :post | nil,
          matcher: Regex.t() | nil,
          handler: handler() | nil
        }

  defstruct [:phase, :matcher, :handler]
end
