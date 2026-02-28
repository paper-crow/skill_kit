defmodule SkillKit.Skill do
  @moduledoc """
  Skill struct, behaviour contract, and unified execute/3 dispatch for SkillKit.

  `SkillKit.Skill` serves two roles:

  1. **Data model** — `%SkillKit.Skill{}` represents a registered skill in the
     registry. It carries both the identity fields used for registry lookups and
     the execution payload (either a module reference or a prompt template body).

  2. **Behaviour contract** — defines 4 required callbacks that Elixir modules
     must implement to act as code-based skills. Missing callbacks produce
     compile-time warnings; `mix compile --warnings-as-errors` hardens them
     into errors.

  ## Skill Types

  SkillKit supports two skill types, distinguished by the `:type` field:

  - **`:code` skills** — Elixir modules implementing `@behaviour SkillKit.Skill`.
    The `:module` field holds the implementing module. `execute/3` delegates to
    `module.execute(args, context)`.

  - **`:prompt` skills** — Markdown files with YAML frontmatter. The `:body`
    field holds the template string. `execute/3` substitutes `{{arg_name}}`
    tokens with values from the `args` map.

  ## Struct Fields

  | Field           | Type                    | Default | Description                                      |
  |-----------------|-------------------------|---------|--------------------------------------------------|
  | `:type`         | `:code \| :prompt`       | `nil`   | Dispatch type — set at construction              |
  | `:name`         | `String.t() \| nil`      | `nil`   | Fully-qualified `"namespace:skill_name"`         |
  | `:namespace`    | `String.t() \| nil`      | `nil`   | Namespace segment extracted from name            |
  | `:description`  | `String.t() \| nil`      | `nil`   | Human-readable description                       |
  | `:required_scope` | `[String.t()]`          | `[]`    | Scopes required to call this skill               |
  | `:module`       | `module() \| nil`        | `nil`   | Implementing module for `:code` skills           |
  | `:body`         | `String.t() \| nil`      | `nil`   | Prompt template body for `:prompt` skills        |
  | `:source`       | `String.t() \| nil`      | `nil`   | File path (prompt) or module name string (code)  |

  ## Naming Convention

  Skill names follow the format `"namespace:skill_name"`, where:
  - Both segments are lowercase, starting with a letter
  - Segments may contain letters, digits, underscores, and hyphens
  - Exactly one colon separates the namespace from the skill name

  Examples: `"files:read"`, `"tools:web-search"`, `"my-org:analyze_data"`

  ## Behaviour Usage

      defmodule MyApp.Skills.Summarize do
        @behaviour SkillKit.Skill

        @impl true
        def name, do: "myapp:summarize"

        @impl true
        def description, do: "Summarizes text content"

        @impl true
        def required_scope, do: ["myapp:read"]

        @impl true
        def execute(args, _context) do
          {:ok, "Summary of: \#{args["text"]}"}
        end
      end

  ## Execute Dispatch

      # Code skill — delegates to module
      skill = %SkillKit.Skill{type: :code, module: MyApp.Skills.Summarize}
      {:ok, result} = SkillKit.Skill.execute(skill, %{"text" => "hello"}, %{})

      # Prompt skill — interpolates template
      skill = %SkillKit.Skill{type: :prompt, body: "Summarize: {{content}}"}
      {:ok, rendered} = SkillKit.Skill.execute(skill, %{"content" => "..."}, %{})
  """

  # ---------------------------------------------------------------------------
  # Behaviour callbacks — required for code-based skill implementations
  # ---------------------------------------------------------------------------

  @doc """
  Returns the fully-qualified skill name in `"namespace:skill_name"` format.
  """
  @callback name() :: String.t()

  @doc """
  Returns a human-readable description of what the skill does.
  """
  @callback description() :: String.t()

  @doc """
  Returns the list of scope strings required to invoke this skill.

  An empty list means no scope restriction. When populated, the authorization
  layer (Phase 3) will check that the calling context possesses all listed scopes.
  """
  @callback required_scope() :: [String.t()]

  @doc """
  Executes the skill with caller-supplied args and an opaque host context.

  - `args` — caller-supplied parameters (string-keyed map)
  - `context` — host-provided opaque map (session info, user identity, etc.)

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback execute(args :: map(), context :: map()) :: {:ok, any()} | {:error, any()}

  # ---------------------------------------------------------------------------
  # Struct definition
  # ---------------------------------------------------------------------------

  @type t :: %__MODULE__{
          type: :code | :prompt | nil,
          name: String.t() | nil,
          namespace: String.t() | nil,
          description: String.t() | nil,
          required_scope: [String.t()],
          module: module() | nil,
          body: String.t() | nil,
          source: String.t() | nil
        }

  defstruct [
    :type,
    :name,
    :namespace,
    :description,
    :module,
    :body,
    :source,
    required_scope: []
  ]

  # ---------------------------------------------------------------------------
  # Unified execute/3 dispatch
  # ---------------------------------------------------------------------------

  @doc """
  Executes a skill through the unified dispatch interface.

  Dispatches based on the `:type` field:
  - `:code` — delegates to `module.execute(args, context)`
  - `:prompt` — interpolates `{{arg_name}}` tokens in `:body` with values from `args`

  Returns `{:ok, result}` on success. For prompt skills, `result` is the
  interpolated template string. For code skills, `result` is whatever the
  module's `execute/2` returns.

  Returns `{:error, {:missing_arg, arg_name}}` when a prompt template references
  a variable not present in `args` — fails fast, no silent gaps.
  """
  @spec execute(t(), map(), map()) :: {:ok, any()} | {:error, any()}
  def execute(%__MODULE__{type: :code, module: mod}, args, context) do
    mod.execute(args, context)
  end

  def execute(%__MODULE__{type: :prompt, body: body}, args, _context) do
    interpolate(body, args)
  end

  # ---------------------------------------------------------------------------
  # Private: Template interpolation
  # ---------------------------------------------------------------------------

  # Replaces all {{var_name}} tokens in body with values from args.
  # Fails fast on the first missing argument — no placeholder leaking.
  @spec interpolate(String.t(), map()) :: {:ok, String.t()} | {:error, {:missing_arg, String.t()}}
  defp interpolate(body, args) do
    result =
      Regex.replace(~r/\{\{(\w+)\}\}/, body, fn _full_match, var_name ->
        case Map.fetch(args, var_name) do
          {:ok, value} -> to_string(value)
          :error -> throw({:missing_arg, var_name})
        end
      end)

    {:ok, result}
  catch
    {:missing_arg, arg_name} -> {:error, {:missing_arg, arg_name}}
  end
end
