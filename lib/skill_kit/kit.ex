defmodule SkillKit.Kit do
  @moduledoc """
  A packaging envelope for skills and agent definitions.

  A Kit bundles related skills and agents loaded from a single source
  (directory, database, API). Backends return Kits; the system unpacks
  them to register skills and discover agent definitions.

  ## `use SkillKit.Kit`

  When a module does `use SkillKit.Kit`, it becomes both a
  `SkillKit.Kit.Provider` (can load skills from `skills/*/SKILL.md`) and a
  `SkillKit.Tool` (can execute them).

  The kit name is inferred from the module's last segment, downcased and
  underscored. Override with `name: "custom_name"`.

  Options:

    * `:skills_dir` — directory containing skill subdirectories (each with a `SKILL.md`).
      Defaults to `skills/` relative to the module's source file.
    * `:name` — override the inferred kit name.

  The macro generates default implementations for `definition/0` and
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
      @behaviour SkillKit.Kit.Provider
      @behaviour SkillKit.Tool

      @kit_name unquote(kit_name)
      @skills_dir unquote(skills_dir)

      @impl SkillKit.Kit.Provider
      def load_kits(config) do
        SkillKit.Kit.do_load_kits(@kit_name, @skills_dir, __MODULE__, config)
      end

      @impl SkillKit.Kit.Provider
      def list_kits(config) do
        load_kits(config)
      end

      @impl SkillKit.Kit.Provider
      def get_kit(config, name) do
        case list_kits(config) do
          {:ok, kits} -> find_kit(kits, name)
          error -> error
        end
      end

      defp find_kit(kits, name) do
        case Enum.find(kits, &(&1.name == name)) do
          nil -> {:error, :not_found}
          kit -> {:ok, kit}
        end
      end

      @impl SkillKit.Tool
      def resume(_execution, _state, _decision) do
        {:error, :not_resumable}
      end

      @impl SkillKit.Tool
      def definition do
        %SkillKit.Tool.Definition{
          name: @kit_name,
          description: "Kit tool for #{@kit_name}",
          input_schema: %{}
        }
      end

      defoverridable resume: 3, definition: 0, load_kits: 1, list_kits: 1, get_kit: 2
    end
  end

  @doc false
  def do_load_kits(kit_name, skills_dir, tool_module, config) do
    case load_skill_files(skills_dir, kit_name, tool_module, config) do
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

  defp load_skill_files(dir, kit_name, tool_module, config) do
    case File.ls(dir) do
      {:ok, entries} -> parse_skill_dirs(entries, dir, kit_name, tool_module, config)
      {:error, :enoent} -> {:ok, []}
    end
  end

  defp parse_skill_dirs(entries, dir, kit_name, tool_module, config) do
    entries
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&skill_dir?/1)
    |> Enum.reduce_while({:ok, []}, fn skill_dir, {:ok, acc} ->
      path = Path.join(skill_dir, "SKILL.md")

      case parse_skill_file(path, kit_name, tool_module, config) do
        {:ok, skill} -> {:cont, {:ok, acc ++ [skill]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp skill_dir?(path) do
    File.dir?(path) and File.exists?(Path.join(path, "SKILL.md"))
  end

  defp parse_skill_file(path, kit_name, tool_module, config) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, yaml_map} <- parse_yaml(frontmatter) do
      build_kit_skill(yaml_map, body, path, kit_name, tool_module, config)
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

  defp build_kit_skill(yaml_map, body, source_path, kit_name, tool_module, config) do
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
         tool: tool_module,
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
