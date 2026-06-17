defmodule SkillKit.Eval do
  @moduledoc """
  An evaluation case for a skill, expressed in a markdown `EVAL.md` file.

  Evals are the test counterpart to skills. Where a `SKILL.md` injects
  instructions into an agent, an `EVAL.md` describes behaviors the skill should
  produce and the criteria for success. The harness loads the skill under test
  into a fresh agent, sends each case's prompt, and asks an LLM judge whether
  the resulting transcript meets the criteria.

  `SkillKit.Eval.Case` turns a directory of `EVAL.md` files into ExUnit tests,
  so `mix test` runs your skill evals as part of the suite.

  ## File Format

  An `EVAL.md` is a suite of cases. Each `##` heading is one case (its text is
  the case name); under it, a `### Prompt` section is the message sent to the
  agent and a `### Expect` section is the rubric the LLM judge scores against.

  ```markdown
  ## greets the user by name
  ### Prompt
  Hi, I'm Sam
  ### Expect
  The assistant greets the user by their name in a warm, friendly tone.

  ## handles a missing name
  ### Prompt
  Hello there
  ### Expect
  The assistant greets politely without inventing a name.
  ```

  ### Skill under test

  When the `EVAL.md` lives next to a `SKILL.md`, that skill is loaded
  automatically — no frontmatter needed. To test a skill elsewhere (or add
  tools / pin a model), use optional frontmatter:

  ```markdown
  ---
  skills:
    - "skills/greeter"
  tools:
    - "SkillKit.Tools.Shell"
  model: "anthropic:claude-sonnet-4-6"
  system: "You are being evaluated."
  ---
  ## greets the user by name
  ...
  ```

  | Frontmatter (all optional) | Notes |
  |----------------------------|-------|
  | `skills` | Skill providers under test (paths or module names). Overrides location inference. |
  | `tools` | Tool providers, same forms as `skills`. |
  | `model` | Model URI for the eval agent; falls back to the default provider. |
  | `system` | System prompt for the eval agent. |

  Headings matching `Prompt`/`Expect` (case-insensitive, any level) are section
  markers; every other `##` heading starts a new case. Other heading levels
  inside a section stay part of its content.

  ### Provider strings

  Entries in `skills`/`tools` are resolved like `SkillKit.start_agent/2`
  providers: a value starting with an uppercase letter is treated as an Elixir
  module name (`"SkillKit.Tools.Shell"`), anything else as a filesystem path
  (`"skills/greeter"`).
  """

  alias SkillKit.Eval.SkillFile
  alias SkillKit.Frontmatter

  @type provider :: module() | String.t() | {module(), keyword()}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          prompt: String.t() | nil,
          system: String.t() | nil,
          model: String.t() | nil,
          rubric: String.t() | nil,
          location: String.t() | nil,
          module: module() | nil,
          agent: String.t() | nil,
          skills: [provider()],
          tools: [provider()],
          metadata: %{optional(String.t()) => term()}
        }

  defstruct [
    :name,
    :prompt,
    :system,
    :model,
    :rubric,
    :location,
    :module,
    :agent,
    skills: [],
    tools: [],
    metadata: %{}
  ]

  @known_sections ~w(prompt expect)

  @doc """
  Colocates evals with the module they exercise via an `@eval` attribute.

  `use SkillKit.Eval` registers an accumulating `@eval` string attribute. Each
  value is a chunk of `EVAL.md` markdown (one or more `##` cases, optional
  frontmatter); they are parsed at compile time and exposed as
  `__skill_evals__/0`. Every case records `module: __MODULE__`, so the eval
  cache keys on the module's compiled hash — change the module's code (or the
  `@eval` text) and the eval re-runs; leave it untouched and a prior pass is
  reused.

      defmodule MyApp.Greeter do
        use SkillKit.Eval

        @eval \"\"\"
        ## greets the user by name
        ### Prompt
        Hi, I'm Sam
        ### Expect
        Greets the user by name.
        \"\"\"
        def greet(name), do: ...
      end

  Point `SkillKit.Eval.Case` at the module(s) with `modules: [MyApp.Greeter]`.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :eval, accumulate: true)
      @before_compile SkillKit.Eval
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    evals =
      env.module
      |> Module.get_attribute(:eval, [])
      |> Enum.reverse()
      |> Enum.flat_map(&parse_attribute!(&1, env.module, env.file))
      |> Macro.escape()

    quote do
      @doc false
      def __skill_evals__, do: unquote(evals)
    end
  end

  defp parse_attribute!(content, module, file) do
    case parse(content, file) do
      {:ok, cases} ->
        Enum.map(cases, &%{&1 | module: module})

      {:error, reason} ->
        raise ArgumentError, "invalid @eval in #{inspect(module)}: #{inspect(reason)}"
    end
  end

  @doc """
  Parses `EVAL.md` content into a list of `%Eval{}` cases.

  Returns `{:ok, evals}` or `{:error, reason}`. `location` is stored on each
  case for diagnostics and skill inference.
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, [t()]} | {:error, term()}
  def parse(content, location \\ nil) do
    with {:ok, yaml, body} <- split_content(content),
         {:ok, cases} <- parse_cases(body) do
      {:ok, build_evals(yaml, cases, location)}
    end
  end

  @doc """
  Loads and parses a single `EVAL.md` file from disk into its list of cases.
  """
  @spec load_file(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def load_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, path)
      {:error, _} = error -> error
    end
  end

  @doc """
  Loads every eval case under `dir`.

  Discovers files named `EVAL.md` or `*.eval.md` at any depth and flattens
  their cases. Returns `{:ok, evals}` ordered by path, or `{:error, {path,
  reason}}` on the first file that fails to parse.
  """
  @spec load_dir(Path.t()) :: {:ok, [t()]} | {:error, {Path.t(), term()}}
  def load_dir(dir) do
    dir
    |> eval_files()
    |> Enum.reduce_while({:ok, []}, &load_into/2)
    |> finalize_dir()
  end

  @doc """
  Like `load_dir/1` but raises on error. Used by `SkillKit.Eval.Case` at
  compile time.
  """
  @spec load_dir!(Path.t()) :: [t()]
  def load_dir!(dir) do
    case load_dir(dir) do
      {:ok, evals} -> evals
      {:error, {path, reason}} -> raise "failed to load eval #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Resolves the skill providers for an eval.

  Returns the explicit `skills` when set, otherwise infers a sibling `SKILL.md`
  next to the eval's file (loaded via `SkillKit.Eval.SkillFile`), or `[]` when
  neither applies.
  """
  @spec skill_providers(t()) :: [provider()]
  def skill_providers(%__MODULE__{skills: [_ | _] = skills}), do: skills

  def skill_providers(%__MODULE__{module: module}) when is_atom(module) and not is_nil(module) do
    if kit_module?(module), do: [module], else: []
  end

  def skill_providers(%__MODULE__{location: location}), do: colocated_skill(location)

  @doc """
  Resolves the tool providers for an eval — its explicit `tools`, plus the
  eval's subject `module` when that module is itself a `SkillKit.Tool`.
  """
  @spec tool_providers(t()) :: [provider()]
  def tool_providers(%__MODULE__{tools: tools, module: module}) do
    maybe_add_tool_module(tools, module)
  end

  defp maybe_add_tool_module(tools, nil), do: tools

  defp maybe_add_tool_module(tools, module) do
    if tool_module?(module) and module not in tools, do: tools ++ [module], else: tools
  end

  defp kit_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :load_kits, 1)
  end

  defp tool_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :definition, 0)
  end

  defp colocated_skill(nil), do: []

  defp colocated_skill(location) do
    path = Path.join(Path.dirname(location), "SKILL.md")
    if File.exists?(path), do: [{SkillFile, path: path}], else: []
  end

  @doc """
  Resolves the agent an eval targets, if any — the directory of an `AGENT.md`
  whose whole identity (system prompt, skills, sub-agents) is run as the
  subject. Returns the explicit `agent:` frontmatter, else the eval's own
  directory when an `AGENT.md` sits beside it (the sidecar pattern), else `nil`.
  When set, the eval runs the agent rather than loading a bare skill.
  """
  @spec agent_source(t()) :: String.t() | nil
  def agent_source(%__MODULE__{agent: path}) when is_binary(path), do: path
  def agent_source(%__MODULE__{location: location}), do: colocated_agent(location)

  defp colocated_agent(nil), do: nil

  defp colocated_agent(location) do
    dir = Path.dirname(location)
    if File.exists?(Path.join(dir, "AGENT.md")), do: dir, else: nil
  end

  # ---------------------------------------------------------------------------
  # Directory loading
  # ---------------------------------------------------------------------------

  defp eval_files(dir) do
    [Path.join(dir, "**/EVAL.md"), Path.join(dir, "**/*.eval.md")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp load_into(path, {:ok, acc}) do
    case load_file(path) do
      {:ok, evals} -> {:cont, {:ok, acc ++ evals}}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp finalize_dir({:ok, _evals} = ok), do: ok
  defp finalize_dir({:error, _} = error), do: error

  # ---------------------------------------------------------------------------
  # Frontmatter (optional)
  # ---------------------------------------------------------------------------

  defp split_content("---\n" <> _rest = content), do: Frontmatter.parse(content)
  defp split_content(content), do: {:ok, %{}, content}

  # ---------------------------------------------------------------------------
  # Case parsing
  # ---------------------------------------------------------------------------

  # Walks the body line by line into a list of `{name, prompt, rubric}` cases.
  # A `##` heading whose text isn't Prompt/Expect starts a new case; a heading
  # named Prompt/Expect (any level) starts a section within the current case;
  # everything else is content under the active section.
  defp parse_cases(body) do
    {current, _section, acc} =
      body
      |> String.split("\n")
      |> Enum.reduce({nil, nil, []}, &reduce_case_line/2)

    current
    |> push_case(acc)
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, &build_case/2)
    |> finalize_cases()
  end

  defp reduce_case_line(line, state), do: apply_line(line_kind(line), line, state)

  defp line_kind(line) do
    cond do
      section_heading?(line) -> {:section, heading_key(line)}
      case_heading?(line) -> {:case, case_name(line)}
      true -> :content
    end
  end

  defp apply_line({:case, name}, _line, {current, _section, acc}) do
    {{name, %{}}, nil, push_case(current, acc)}
  end

  defp apply_line({:section, _key}, _line, {nil, _section, acc}), do: {nil, nil, acc}
  defp apply_line({:section, key}, _line, {current, _section, acc}), do: {current, key, acc}

  defp apply_line(:content, line, {current, section, acc}) do
    {add_content(current, section, line), section, acc}
  end

  defp add_content(nil, _section, _line), do: nil
  defp add_content(current, nil, _line), do: current

  defp add_content({name, sections}, section, line) do
    {name, Map.update(sections, section, [line], &[line | &1])}
  end

  defp push_case(nil, acc), do: acc
  defp push_case(case_tuple, acc), do: [case_tuple | acc]

  defp build_case({name, sections}, {:ok, list}) do
    with {:ok, prompt} <- section_value(sections, "prompt", name),
         {:ok, rubric} <- section_value(sections, "expect", name) do
      {:cont, {:ok, [{name, prompt, rubric} | list]}}
    else
      error -> {:halt, error}
    end
  end

  defp section_value(sections, key, name) do
    value =
      sections
      |> Map.get(key, [])
      |> join_section()

    if value == "", do: {:error, {:missing_section, key, name}}, else: {:ok, value}
  end

  defp join_section(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp finalize_cases({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp finalize_cases({:error, _} = error), do: error

  # ---------------------------------------------------------------------------
  # Heading detection
  # ---------------------------------------------------------------------------

  defp section_heading?("#" <> _rest = line), do: heading_key(line) in @known_sections
  defp section_heading?(_line), do: false

  defp case_heading?("## " <> _rest), do: true
  defp case_heading?(_line), do: false

  defp case_name("## " <> rest), do: String.trim(rest)

  defp heading_key(line) do
    line
    |> String.trim_leading("#")
    |> String.trim()
    |> String.downcase()
  end

  # ---------------------------------------------------------------------------
  # Struct construction
  # ---------------------------------------------------------------------------

  defp build_evals(yaml, cases, location) do
    Enum.map(cases, &build_eval(&1, yaml, location))
  end

  defp build_eval({name, prompt, rubric}, yaml, location) do
    %__MODULE__{
      name: name,
      prompt: prompt,
      rubric: rubric,
      location: location,
      module: resolve_module(Map.get(yaml, "module")),
      agent: Map.get(yaml, "agent"),
      system: Map.get(yaml, "system"),
      model: Map.get(yaml, "model"),
      skills: providers(Map.get(yaml, "skills")),
      tools: providers(Map.get(yaml, "tools")),
      metadata: Map.get(yaml, "metadata", %{})
    }
  end

  defp resolve_module(nil), do: nil
  defp resolve_module(name) when is_binary(name), do: Module.concat([name])
  defp resolve_module(module) when is_atom(module), do: module

  defp providers(nil), do: []
  defp providers(specs) when is_list(specs), do: Enum.map(specs, &resolve_provider/1)
  defp providers(spec), do: providers([spec])

  defp resolve_provider(spec) when is_binary(spec) do
    if module_name?(spec), do: Module.concat([spec]), else: spec
  end

  defp resolve_provider(spec), do: spec

  defp module_name?(string), do: Regex.match?(~r/^[A-Z][A-Za-z0-9_.]*$/, string)
end
