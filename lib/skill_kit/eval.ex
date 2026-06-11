defmodule SkillKit.Eval do
  @moduledoc """
  An evaluation case for a skill, expressed as a markdown `EVAL.md` file.

  Evals are the test counterpart to skills. Where a `SKILL.md` injects
  instructions into an agent, an `EVAL.md` describes a behavior the skill
  should produce and the criteria for success. The eval harness loads the
  skill(s) under test into a fresh agent, sends the eval's prompt, and scores
  the resulting transcript against the eval's expectations — both deterministic
  (`expect`) and natural-language (the body, scored by an LLM judge).

  `SkillKit.Eval.Case` turns a directory of `EVAL.md` files into ExUnit tests,
  so `mix test` runs your skill evals as part of the suite.

  ## File Format

  ```markdown
  ---
  name: "greets the user by name"
  description: "The greeter skill should address the user warmly"
  skills:
    - "test/eval/fixtures/greeter"
  tools:
    - "SkillKit.Tools.Shell"
  prompt: "Hi, I'm Sam"
  model: "anthropic:claude-sonnet-4-20250514"
  expect:
    response: ["Sam"]
    not_response: ["error"]
    tools: ["bash"]
  ---
  The assistant greets the user by their name in a warm, friendly tone.
  ```

  ### Frontmatter Fields

  | Field | Type | Notes |
  |-------|------|-------|
  | `name` | `String.t()` | Required. Used as the ExUnit test name. |
  | `prompt` | `String.t()` | Required. The user message sent to the agent. |
  | `description` | `String.t()` | Optional human-readable summary. |
  | `system` | `String.t()` | Optional system prompt for the eval agent. |
  | `model` | `String.t()` | Optional model URI; falls back to the default provider. |
  | `skills` | `[String.t()]` | Skill providers under test (paths or module names). |
  | `tools` | `[String.t()]` | Tool providers (paths or module names). |
  | `expect.response` | `String.t() \\| [String.t()]` | Substrings the final response must contain. |
  | `expect.not_response` | `String.t() \\| [String.t()]` | Substrings the response must NOT contain. |
  | `expect.tools` | `String.t() \\| [String.t()]` | Tool names the agent must call. |

  The markdown body (below the second `---`) is the LLM-judge rubric. Leave it
  empty to skip judging and rely on the deterministic `expect` checks alone.

  ### Provider strings

  Entries in `skills`/`tools` are resolved like `SkillKit.start_agent/2`
  providers: a value starting with an uppercase letter is treated as an Elixir
  module name (`"SkillKit.Tools.Shell"`), anything else as a filesystem path
  (`"test/eval/fixtures/greeter"`).
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
          expect_response: [String.t()],
          refute_response: [String.t()],
          expect_tools: [String.t()],
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
    expect_response: [],
    refute_response: [],
    expect_tools: [],
    metadata: %{}
  ]

  @doc """
  Parses `EVAL.md` content into an `%Eval{}` struct.

  Returns `{:ok, eval}` or `{:error, reason}`. `location` is stored on the
  struct for diagnostics and is otherwise optional.
  """
  @spec parse(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse(content, location \\ nil) do
    with {:ok, yaml, body} <- Frontmatter.parse(content),
         {:ok, name} <- fetch_required(yaml, "name"),
         {:ok, prompt} <- fetch_required(yaml, "prompt") do
      {:ok, build(yaml, body, name, prompt, location)}
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
  # Struct construction
  # ---------------------------------------------------------------------------

  defp build(yaml, body, name, prompt, location) do
    expect = expect_map(Map.get(yaml, "expect"))

    %__MODULE__{
      name: name,
      description: Map.get(yaml, "description"),
      prompt: prompt,
      system: Map.get(yaml, "system"),
      model: Map.get(yaml, "model"),
      rubric: rubric(body),
      location: location,
      skills: providers(Map.get(yaml, "skills")),
      tools: providers(Map.get(yaml, "tools")),
      expect_response: to_list(Map.get(expect, "response")),
      refute_response: to_list(Map.get(expect, "not_response")),
      expect_tools: to_list(Map.get(expect, "tools")),
      metadata: Map.get(yaml, "metadata", %{})
    }
  end

  defp expect_map(map) when is_map(map), do: map
  defp expect_map(_other), do: %{}

  defp rubric(nil), do: nil
  defp rubric(""), do: nil
  defp rubric(body) when is_binary(body), do: body

  defp providers(nil), do: []
  defp providers(specs) when is_list(specs), do: Enum.map(specs, &resolve_provider/1)
  defp providers(spec), do: providers([spec])

  defp resolve_provider(spec) when is_binary(spec) do
    if module_name?(spec), do: Module.concat([spec]), else: spec
  end

  defp resolve_provider(spec), do: spec

  defp module_name?(string), do: Regex.match?(~r/^[A-Z][A-Za-z0-9_.]*$/, string)

  defp to_list(nil), do: []
  defp to_list(list) when is_list(list), do: list
  defp to_list(value), do: [value]

  defp fetch_required(yaml, key) do
    case Map.get(yaml, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
