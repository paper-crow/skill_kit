defmodule SkillKit.Kit do
  @moduledoc """
  A packaging envelope for skills and agent definitions.

  A Kit bundles related skills and agents loaded from a single source
  (directory, database, API). Backends return Kits; the system unpacks
  them to register skills and discover agent definitions.

  ## `use SkillKit.Kit`

  When a module does `use SkillKit.Kit`, it becomes both a
  `SkillKit.Kit.Provider` (can load skills from `skills/*/SKILL.md`) and a
  `SkillKit.Tool` (can execute them). All skill and agent files are read
  and parsed at compile time — no runtime filesystem access is needed.

  The kit name is inferred from the module's last segment, downcased and
  underscored. Override with `name: "custom_name"`.

  Options:

    * `:path` — the kit root directory. Skills are loaded from `<path>/skills/`
      and `AGENT.md` from `<path>/AGENT.md`. Defaults to the directory containing
      the module's source file.
    * `:name` — override the inferred kit name.

  The macro generates default implementations for `definition/0`, `resume/3`,
  `load_kits/1`, `list_kits/1`, `get_kit/2`, and `agent_definition/0`. All are
  overridable. The using module must define `execute/1`.

  `agent_definition/0` returns the parsed `%SkillKit.Agent{}` from
  the kit's `AGENT.md`, or `nil` if no agent file exists.
  """

  alias SkillKit.Agent
  alias SkillKit.Skill

  @type t :: %__MODULE__{
          name: String.t(),
          skills: [Skill.t()],
          subagents: [Agent.t()],
          agent: Agent.t() | nil,
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct [
    :name,
    :agent,
    skills: [],
    subagents: [],
    metadata: %{}
  ]

  defmacro __using__(opts) do
    caller_dir = Path.dirname(__CALLER__.file)
    kit_path = resolve_path(opts, caller_dir, __CALLER__)
    skills_dir = Path.join(kit_path, "skills")
    kit_name = Keyword.get(opts, :name, infer_kit_name(__CALLER__.module))

    # Compile-time: read and parse all SKILL.md and AGENT.md files
    {:ok, skills} = compile_skills(skills_dir, kit_name)
    agent = compile_agent(kit_path)
    resource_paths = compile_resource_paths(skills_dir, kit_path)

    quote do
      @behaviour SkillKit.Kit.Provider
      @behaviour SkillKit.Tool

      # Track files for recompilation when they change
      for path <- unquote(resource_paths) do
        @external_resource path
      end

      @kit_name unquote(kit_name)

      # Patch tool module — not available at macro expansion time
      @compiled_skills Enum.map(
                         unquote(Macro.escape(skills)),
                         &Map.put(&1, :tool, __MODULE__)
                       )

      @compiled_agent unquote(Macro.escape(agent))

      @impl SkillKit.Kit.Provider
      def load_kits(config) do
        skills = patch_source_config(@compiled_skills, config)
        kit = %SkillKit.Kit{name: @kit_name, skills: skills, agent: @compiled_agent}
        {:ok, [kit]}
      end

      @impl SkillKit.Kit.Provider
      def list_kits(config), do: load_kits(config)

      @impl SkillKit.Kit.Provider
      def get_kit(config, name) do
        case list_kits(config) do
          {:ok, kits} ->
            case Enum.find(kits, &(&1.name == name)) do
              nil -> {:error, :not_found}
              kit -> {:ok, kit}
            end

          error ->
            error
        end
      end

      @doc "Returns the agent definition from AGENT.md, or nil if not present."
      def agent_definition, do: @compiled_agent

      @impl SkillKit.Tool
      def resume(_execution, _state, _decision), do: {:error, :not_resumable}

      @impl SkillKit.Tool
      def definition do
        %SkillKit.Tool{
          name: @kit_name,
          description: "Kit tool for #{@kit_name}",
          input_schema: %{}
        }
      end

      defp patch_source_config(skills, config) do
        Enum.map(skills, fn skill ->
          %{skill | metadata: Map.put(skill.metadata, "source_config", config)}
        end)
      end

      defoverridable resume: 3,
                     definition: 0,
                     load_kits: 1,
                     list_kits: 1,
                     get_kit: 2,
                     agent_definition: 0
    end
  end

  # --- Compile-time helpers (called during macro expansion) ---

  @doc false
  def compile_skills(skills_dir, kit_name) do
    case File.ls(skills_dir) do
      {:ok, entries} ->
        skills =
          entries
          |> Enum.sort()
          |> Enum.map(&Path.join(skills_dir, &1))
          |> Enum.filter(&skill_dir?/1)
          |> Enum.flat_map(&compile_skill(&1, kit_name))

        {:ok, skills}

      {:error, :enoent} ->
        {:ok, []}
    end
  end

  @doc false
  def compile_agent(kit_path) do
    agent_path = Path.join(kit_path, "AGENT.md")

    with {:ok, content} <- File.read(agent_path),
         {:ok, agent} <- Agent.parse(content) do
      agent
    else
      _ -> nil
    end
  end

  @doc false
  def compile_resource_paths(skills_dir, kit_path) do
    skill_paths =
      case File.ls(skills_dir) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(skills_dir, &1))
          |> Enum.filter(&skill_dir?/1)
          |> Enum.map(&Path.join(&1, "SKILL.md"))

        {:error, _} ->
          []
      end

    agent_path = Path.join(kit_path, "AGENT.md")
    agent_paths = if File.exists?(agent_path), do: [agent_path], else: []

    skill_paths ++ agent_paths
  end

  defp compile_skill(skill_dir, kit_name) do
    path = Path.join(skill_dir, "SKILL.md")

    case parse_skill_file(path, kit_name) do
      {:ok, skill} -> [skill]
      {:error, _} -> []
    end
  end

  defp resolve_path(opts, caller_dir, caller_env) do
    case Keyword.get(opts, :path) do
      nil -> caller_dir
      path when is_binary(path) -> path
      quoted -> elem(Code.eval_quoted(quoted, [], caller_env), 0)
    end
  end

  defp infer_kit_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp skill_dir?(path) do
    File.dir?(path) and File.exists?(Path.join(path, "SKILL.md"))
  end

  defp parse_skill_file(path, kit_name) do
    with {:ok, content} <- File.read(path),
         {:ok, yaml_map, body} <- SkillKit.Frontmatter.parse(content) do
      build_kit_skill(yaml_map, body, path, kit_name)
    end
  end

  defp build_kit_skill(yaml_map, body, source_path, kit_name) do
    with {:ok, bare_name} <- fetch_required_string(yaml_map, "name"),
         {:ok, description} <- fetch_required_string(yaml_map, "description") do
      qualified_name = "#{kit_name}:#{bare_name}"
      metadata = Map.get(yaml_map, "metadata", %{})

      {:ok,
       %Skill{
         name: qualified_name,
         namespace: kit_name,
         description: description,
         body: body,
         location: source_path,
         tool: nil,
         metadata: metadata
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
