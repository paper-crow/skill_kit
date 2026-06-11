defmodule SkillKit.Eval do
  @moduledoc """
  An evaluation case for a skill, expressed as a markdown `EVAL.md` file.

  Evals are the test counterpart to skills. Where a `SKILL.md` injects
  instructions into an agent, an `EVAL.md` describes a behavior the skill
  should produce and the criteria for success. The eval harness loads the
  skill(s) under test into a fresh agent, sends the eval's prompt, and asks an
  LLM judge whether the resulting transcript meets the criteria.

  `SkillKit.Eval.Case` turns a directory of `EVAL.md` files into ExUnit tests,
  so `mix test` runs your skill evals as part of the suite.

  ## File Format

  Frontmatter is just wiring — which skill is under test and how to run it. The
  body carries the test itself in two sections: `## Prompt` (the message sent
  to the agent) and `## Expect` (the natural-language rubric the LLM judge
  scores against).

  ```markdown
  ---
  name: "greets the user by name"
  description: "The greeter should address the user warmly"
  skills:
    - "skills/greeter"
  tools:
    - "SkillKit.Tools.Shell"
  model: "anthropic:claude-sonnet-4-20250514"
  ---
  ## Prompt
  Hi, I'm Sam

  ## Expect
  The assistant greets the user by their name in a warm, friendly tone.
  ```

  ### Frontmatter Fields

  | Field | Type | Notes |
  |-------|------|-------|
  | `name` | `String.t()` | Required. Used as the ExUnit test name. |
  | `description` | `String.t()` | Optional human-readable summary. |
  | `system` | `String.t()` | Optional system prompt for the eval agent. |
  | `model` | `String.t()` | Optional model URI; falls back to the default provider. |
  | `skills` | `[String.t()]` | Skill providers under test (paths or module names). |
  | `tools` | `[String.t()]` | Tool providers (paths or module names). |

  ### Body Sections

  | Section | Required | Role |
  |---------|----------|------|
  | `## Prompt` | yes | The user message sent to the agent under test. |
  | `## Expect` | yes | The rubric the LLM judge scores the transcript against. |

  Headings are matched case-insensitively at any level (`#`–`######`). Only the
  exact words `Prompt` and `Expect` start a section, so a `#`-prefixed line
  inside a section (e.g. a shell comment) stays part of that section's content.

  ### Provider strings

  Entries in `skills`/`tools` are resolved like `SkillKit.start_agent/2`
  providers: a value starting with an uppercase letter is treated as an Elixir
  module name (`"SkillKit.Tools.Shell"`), anything else as a filesystem path
  (`"skills/greeter"`).
  """

  alias SkillKit.Frontmatter

  @type provider :: module() | String.t() | {module(), keyword()}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          description: String.t() | nil,
          prompt: String.t() | nil,
          system: String.t() | nil,
          model: String.t() | nil,
          rubric: String.t() | nil,
          location: String.t() | nil,
          skills: [provider()],
          tools: [provider()],
          metadata: %{optional(String.t()) => term()}
        }

  defstruct [
    :name,
    :description,
    :prompt,
    :system,
    :model,
    :rubric,
    :location,
    skills: [],
    tools: [],
    metadata: %{}
  ]

  @known_sections ~w(prompt expect)

  @doc """
  Parses `EVAL.md` content into an `%Eval{}` struct.

  Returns `{:ok, eval}` or `{:error, reason}`. `location` is stored on the
  struct for diagnostics and is otherwise optional.
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(content, location \\ nil) do
    with {:ok, yaml, body} <- Frontmatter.parse(content),
         {:ok, name} <- fetch_required(yaml, "name"),
         sections = sections(body),
         {:ok, prompt} <- fetch_section(sections, "prompt"),
         {:ok, rubric} <- fetch_section(sections, "expect") do
      {:ok, build(yaml, name, prompt, rubric, location)}
    end
  end

  @doc """
  Loads and parses a single `EVAL.md` file from disk.
  """
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_file(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, path)
      {:error, _} = error -> error
    end
  end

  @doc """
  Loads every eval under `dir`.

  Discovers files named `EVAL.md` or `*.eval.md` at any depth. Returns
  `{:ok, evals}` sorted by path, or `{:error, {path, reason}}` on the first
  file that fails to parse.
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
      {:ok, eval} -> {:cont, {:ok, [eval | acc]}}
      {:error, reason} -> {:halt, {:error, {path, reason}}}
    end
  end

  defp finalize_dir({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp finalize_dir({:error, _} = error), do: error

  # ---------------------------------------------------------------------------
  # Body section parsing
  # ---------------------------------------------------------------------------

  # Splits the markdown body into a map of normalized section title => content.
  # Only the headings in @known_sections start a new section; every other line
  # (including other `#` lines) is content under the current section.
  defp sections(body) do
    {_current, acc} =
      body
      |> String.split("\n")
      |> Enum.reduce({nil, %{}}, &reduce_section_line/2)

    Map.new(acc, fn {title, lines} -> {title, join_section(lines)} end)
  end

  defp reduce_section_line(line, {current, acc}) do
    case section_boundary(line) do
      {:ok, title} -> {title, Map.put_new(acc, title, [])}
      :error -> {current, add_line(acc, current, line)}
    end
  end

  defp section_boundary("#" <> _rest = line) do
    title = heading_text(line)
    if title in @known_sections, do: {:ok, title}, else: :error
  end

  defp section_boundary(_line), do: :error

  defp heading_text(line) do
    line
    |> String.trim_leading("#")
    |> String.trim()
    |> String.downcase()
  end

  defp add_line(acc, nil, _line), do: acc
  defp add_line(acc, title, line), do: Map.update(acc, title, [line], &[line | &1])

  defp join_section(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp fetch_section(sections, key) do
    case Map.get(sections, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_section, key}}
    end
  end

  # ---------------------------------------------------------------------------
  # Struct construction
  # ---------------------------------------------------------------------------

  defp build(yaml, name, prompt, rubric, location) do
    %__MODULE__{
      name: name,
      description: Map.get(yaml, "description"),
      prompt: prompt,
      system: Map.get(yaml, "system"),
      model: Map.get(yaml, "model"),
      rubric: rubric,
      location: location,
      skills: providers(Map.get(yaml, "skills")),
      tools: providers(Map.get(yaml, "tools")),
      metadata: Map.get(yaml, "metadata", %{})
    }
  end

  defp providers(nil), do: []
  defp providers(specs) when is_list(specs), do: Enum.map(specs, &resolve_provider/1)
  defp providers(spec), do: providers([spec])

  defp resolve_provider(spec) when is_binary(spec) do
    if module_name?(spec), do: Module.concat([spec]), else: spec
  end

  defp resolve_provider(spec), do: spec

  defp module_name?(string), do: Regex.match?(~r/^[A-Z][A-Za-z0-9_.]*$/, string)

  defp fetch_required(yaml, key) do
    case Map.get(yaml, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
