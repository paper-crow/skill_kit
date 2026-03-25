defmodule SkillKit.Kit do
  @moduledoc """
  A packaging envelope for skills and agent definitions.

  A Kit bundles related skills and agents loaded from a single source
  (directory, database, API). Backends return Kits; the system unpacks
  them to register skills and discover agent definitions.

  ## `use SkillKit.Kit`

  When a module does `use SkillKit.Kit`, it becomes both a
  `SkillKit.Backend` (can load skills from `*.skill.md` files) and a
  `SkillKit.Handler.Behaviour` (can execute them).

  The kit name is inferred from the module's last segment, downcased and
  underscored. Override with `name: "custom_name"`.

  Options:

    * `:skills_dir` — directory containing `*.skill.md` files.
      Defaults to `skills/` relative to the module's source file.
    * `:name` — override the inferred kit name.

  The macro generates default implementations for `tool_definition/0` and
  `resume/3` but does NOT generate `execute/1` — the using module must
  define that callback itself.
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Skill

  @type t :: %__MODULE__{
          name: String.t(),
          skills: [Skill.t()],
          agents: [Definition.t()],
          root_agent: Definition.t() | nil,
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :root_agent,
    skills: [],
    agents: [],
    metadata: %{}
  ]

  defmacro __using__(opts) do
    skills_dir = Keyword.get(opts, :skills_dir, default_skills_dir(__CALLER__))
    kit_name = Keyword.get(opts, :name, infer_kit_name(__CALLER__.module))

    quote do
      @behaviour SkillKit.Backend
      @behaviour SkillKit.Handler.Behaviour

      @kit_name unquote(kit_name)
      @skills_dir unquote(skills_dir)

      @impl SkillKit.Backend
      def load_kits(config) do
        SkillKit.Kit.do_load_kits(@kit_name, @skills_dir, __MODULE__, config)
      end

      @impl SkillKit.Handler.Behaviour
      def resume(_execution, _state, _decision) do
        {:error, :not_resumable}
      end

      @impl SkillKit.Handler.Behaviour
      def tool_definition do
        %SkillKit.Handler.ToolDefinition{
          name: @kit_name,
          description: "Kit handler for #{@kit_name}",
          input_schema: %{}
        }
      end

      defoverridable resume: 3, tool_definition: 0
    end
  end

  @doc false
  def do_load_kits(kit_name, skills_dir, handler_module, config) do
    case load_skill_files(skills_dir, kit_name, handler_module, config) do
      {:ok, skills} ->
        kit = %__MODULE__{name: kit_name, skills: skills}
        {:ok, [kit]}

      {:error, _} = error ->
        error
    end
  end

  # --- Private helpers ---

  defp default_skills_dir(caller) do
    caller_dir = Path.dirname(caller.file)

    quote do
      Path.join(unquote(caller_dir), "skills")
    end
  end

  defp infer_kit_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp load_skill_files(dir, kit_name, handler_module, config) do
    pattern = Path.join(dir, "*.skill.md")

    pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case parse_skill_file(path, kit_name, handler_module, config) do
        {:ok, skill} -> {:cont, {:ok, acc ++ [skill]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_skill_file(path, kit_name, handler_module, config) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, yaml_map} <- parse_yaml(frontmatter) do
      build_kit_skill(yaml_map, body, path, kit_name, handler_module, config)
    end
  end

  defp split_frontmatter(content) do
    rest = strip_opening_delimiter(content)

    case String.split(rest, ~r/\n---(\n|$)/, parts: 2) do
      [frontmatter, body] -> {:ok, frontmatter, String.trim(body)}
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp strip_opening_delimiter(content) do
    if String.starts_with?(content, "---\n") do
      String.slice(content, 4, byte_size(content))
    else
      content
    end
  end

  defp parse_yaml(yaml_str) do
    YamlElixir.read_from_string(yaml_str, atoms: false)
  end

  defp build_kit_skill(yaml_map, body, source_path, kit_name, handler_module, config) do
    with {:ok, bare_name} <- fetch_required_string(yaml_map, "name"),
         {:ok, description} <- fetch_required_string(yaml_map, "description") do
      qualified_name = "#{kit_name}:#{bare_name}"
      metadata = Map.get(yaml_map, "metadata", %{})
      merged_metadata = Map.put(metadata, "source_config", config)

      {:ok,
       %Skill{
         name: qualified_name,
         namespace: kit_name,
         description: description,
         body: body,
         location: source_path,
         handler: handler_module,
         metadata: merged_metadata
       }}
    end
  end

  defp fetch_required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
