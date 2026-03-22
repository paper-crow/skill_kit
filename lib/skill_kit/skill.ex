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
  | `:metadata`       | `%{String.t() => term()}` | `%{}`              | Arbitrary key-value metadata from frontmatter |

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
          hooks: [Hook.t()],
          metadata: %{optional(String.t()) => term()}
        }

  defstruct [
    :name,
    :namespace,
    :description,
    :body,
    :location,
    required_scope: [],
    executor: SkillKit.Executor.Shell,
    hooks: [],
    metadata: %{}
  ]

  @doc """
  Renders the skill body by substituting template tokens with values from `args`.

  Supported tokens:
  - `$ARGUMENTS` — all arguments as a single string (from `args["arguments"]`)
  - `$ARGUMENTS[N]` — positional argument by 0-based index (space-split)
  - `$N` — shorthand for `$ARGUMENTS[N]` (e.g., `$0`, `$1`)
  - `${CLAUDE_SKILL_DIR}` — directory of the skill (derived from `:location` field)
  - `${CLAUDE_SESSION_ID}` — session ID (from `args["session_id"]`)

  If `$ARGUMENTS` (or `$N`) is NOT present in the body but arguments are provided,
  appends `\\n\\nARGUMENTS: <value>` to the end.

  Returns `{:ok, ""}` when body is `nil`.
  """
  @spec render(t(), map()) :: {:ok, String.t()}
  def render(%__MODULE__{body: nil}, _args), do: {:ok, ""}

  def render(%__MODULE__{body: body, location: location}, args) do
    arguments = Map.get(args, "arguments", "")
    session_id = Map.get(args, "session_id", "")
    positional = if arguments != "", do: String.split(arguments, " "), else: []

    has_arguments_token =
      String.contains?(body, "$ARGUMENTS") or
        Regex.match?(~r/\$\d+(?!\])/, body)

    result =
      body
      |> substitute_arguments_indexed(positional)
      |> substitute_arguments(arguments)
      |> substitute_shorthand(positional)
      |> substitute_skill_dir(location)
      |> substitute_session_id(session_id)

    result =
      if not has_arguments_token and arguments != "" do
        result <> "\n\nARGUMENTS: #{arguments}"
      else
        result
      end

    {:ok, result}
  end

  defp substitute_arguments_indexed(body, positional) do
    Regex.replace(~r/\$ARGUMENTS\[(\d+)\]/, body, fn _, index ->
      i = String.to_integer(index)
      Enum.at(positional, i, "")
    end)
  end

  defp substitute_arguments(body, arguments) do
    String.replace(body, "$ARGUMENTS", arguments)
  end

  defp substitute_shorthand(body, positional) do
    Regex.replace(~r/\$(\d+)(?!\])/, body, fn _, index ->
      i = String.to_integer(index)
      Enum.at(positional, i, "")
    end)
  end

  defp substitute_skill_dir(body, nil), do: body

  defp substitute_skill_dir(body, location) do
    dir = Path.dirname(location)
    String.replace(body, "${CLAUDE_SKILL_DIR}", dir)
  end

  defp substitute_session_id(body, session_id) do
    String.replace(body, "${CLAUDE_SESSION_ID}", session_id)
  end
end
