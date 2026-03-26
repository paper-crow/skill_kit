defmodule SkillKit.CatalogTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition
  alias SkillKit.Catalog
  alias SkillKit.Hook
  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  # --- Test scope struct ---

  defmodule TestScope do
    defstruct permissions: []
  end

  defimpl SkillKit.Scope, for: TestScope do
    def permissions(scope), do: scope.permissions
    def resolve(_scope, _variable, _context), do: :error
  end

  # --- Failing provider for error handling ---

  defmodule FailingProvider do
    @behaviour SkillKit.Kit.Provider

    @impl true
    def list_kits(_config), do: {:error, :connection_refused}

    @impl true
    def get_kit(_config, _name), do: {:error, :not_found}
  end

  # --- Helpers ---

  defp start_catalog(provider, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    extra_providers = Keyword.get(opts, :extra_providers, [])
    providers = [{Memory, provider: provider} | extra_providers]
    start_supervised!({Catalog, providers: providers, scope: scope})
  end

  defp make_skill(name, opts \\ []) do
    %Skill{
      name: name,
      description: Keyword.get(opts, :description, "#{name} skill"),
      body: Keyword.get(opts, :body, "do the thing"),
      tool: Keyword.get(opts, :tool, SkillKit.Tools.Shell),
      required_scope: Keyword.get(opts, :required_scope, []),
      hooks: Keyword.get(opts, :hooks, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp make_agent(name, opts \\ []) do
    %Definition{
      name: name,
      description: Keyword.get(opts, :description, "#{name} agent"),
      system_prompt: "You are #{name}.",
      path: "/test/#{name}"
    }
  end

  # =====================================================================
  # list_skills
  # =====================================================================

  describe "list_skills/1" do
    test "returns {name, description} tuples" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:hello", description: "Says hello"))
      Memory.put(provider, make_skill("ns:goodbye", description: "Says goodbye"))

      catalog = start_catalog(provider)
      skills = Catalog.list_skills(catalog)

      assert Enum.sort(skills) == [
               {"ns:goodbye", "Says goodbye"},
               {"ns:hello", "Says hello"}
             ]
    end

    test "filters by authorization when scope is set" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:public"))
      Memory.put(provider, make_skill("ns:admin", required_scope: ["admin:read"]))

      scope = %TestScope{permissions: []}
      catalog = start_catalog(provider, scope: scope)

      skills = Catalog.list_skills(catalog)
      assert skills == [{"ns:public", "ns:public skill"}]
    end

    test "shows all skills when scope is nil" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:public"))
      Memory.put(provider, make_skill("ns:admin", required_scope: ["admin:read"]))

      catalog = start_catalog(provider)
      assert length(Catalog.list_skills(catalog)) == 2
    end
  end

  # =====================================================================
  # get_skill
  # =====================================================================

  describe "get_skill/2" do
    test "returns full skill" do
      {:ok, provider} = Memory.start_link([])
      skill = make_skill("ns:hello", description: "Says hello")
      Memory.put(provider, skill)

      catalog = start_catalog(provider)
      assert {:ok, fetched} = Catalog.get_skill(catalog, "ns:hello")
      assert fetched.name == "ns:hello"
      assert fetched.description == "Says hello"
    end

    test "returns :not_found for unknown skill" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert {:error, :not_found} = Catalog.get_skill(catalog, "ns:nope")
    end

    test "returns :unauthorized when scope doesn't cover required_scope" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:admin", required_scope: ["admin:write"]))

      scope = %TestScope{permissions: ["user:read"]}
      catalog = start_catalog(provider, scope: scope)

      assert {:error, :unauthorized} = Catalog.get_skill(catalog, "ns:admin")
    end
  end

  # =====================================================================
  # list_agents
  # =====================================================================

  describe "list_agents/1" do
    test "returns definitions from kits" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer")
      kit = %Kit{name: "test", agents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      agents = Catalog.list_agents(catalog)

      assert length(agents) == 1
      assert hd(agents).name == "reviewer"
    end
  end

  # =====================================================================
  # get_agent
  # =====================================================================

  describe "get_agent/2" do
    test "returns agent by name" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer")
      kit = %Kit{name: "test", agents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      assert {:ok, found} = Catalog.get_agent(catalog, "reviewer")
      assert found.name == "reviewer"
    end

    test "returns :not_found for unknown agent" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert {:error, :not_found} = Catalog.get_agent(catalog, "nope")
    end
  end

  # =====================================================================
  # root_agent
  # =====================================================================

  describe "root_agent/1" do
    test "returns root agent when set" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("main")
      kit = %Kit{name: "test", root_agent: agent}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      root = Catalog.root_agent(catalog)
      assert root.name == "main"
    end

    test "returns nil when no root agent" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:hello"))

      catalog = start_catalog(provider)
      assert Catalog.root_agent(catalog) == nil
    end
  end

  # =====================================================================
  # hooks
  # =====================================================================

  describe "hooks/1" do
    test "returns hooks from skills" do
      {:ok, provider} = Memory.start_link([])
      hook = %Hook{phase: :pre, matcher: ~r/Shell/, handler: fn _ -> :ok end}
      Memory.put(provider, make_skill("ns:hooked", hooks: [hook]))

      catalog = start_catalog(provider)
      hooks = Catalog.hooks(catalog)
      assert length(hooks) == 1
      assert hd(hooks).phase == :pre
    end
  end

  # =====================================================================
  # tool_definitions
  # =====================================================================

  describe "tool_definitions/2" do
    test "includes activate_skill when skills exist" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:hello", description: "Says hello"))

      catalog = start_catalog(provider)
      tools = Catalog.tool_definitions(catalog, [])

      activate = Enum.find(tools, &(&1.name == "activate_skill"))
      assert activate != nil
      assert activate.input_schema["properties"]["name"]["enum"] == ["ns:hello"]
    end

    test "includes builtins when subagent: true" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)

      tools = Catalog.tool_definitions(catalog, subagent: true)
      names = Enum.map(tools, & &1.name)
      assert "report_status" in names
      assert "report_result" in names
    end

    test "excludes builtins when subagent: false" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)

      tools = Catalog.tool_definitions(catalog, [])
      names = Enum.map(tools, & &1.name)
      refute "report_status" in names
    end

    test "includes agent tools" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer", description: "Reviews code")
      kit = %Kit{name: "test", agents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      tools = Catalog.tool_definitions(catalog, [])

      agent_tool = Enum.find(tools, &(&1.name == "reviewer"))
      assert agent_tool != nil
      assert agent_tool.input_schema["properties"]["task"] != nil
      assert agent_tool.input_schema["required"] == ["task"]
    end

    test "includes tool definitions from kit metadata" do
      {:ok, provider} = Memory.start_link([])

      kit = %Kit{
        name: "shell_kit",
        skills: [],
        metadata: %{tool: SkillKit.Tools.Shell}
      }

      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      tools = Catalog.tool_definitions(catalog, [])

      tool_def = Enum.find(tools, &(&1.name == SkillKit.Tools.Shell.definition().name))
      assert tool_def != nil
    end

    test "includes activated skill tools" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)

      activated = [make_skill("ns:schedule", tool: SkillKit.Tools.Shell)]
      tools = Catalog.tool_definitions(catalog, activated_skills: activated)

      skill_tool = Enum.find(tools, &(&1.name == "schedule"))
      assert skill_tool != nil
    end
  end

  # =====================================================================
  # classify
  # =====================================================================

  describe "classify/3" do
    test "classifies activate_skill" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "activate_skill") == :activate_skill
    end

    test "classifies builtins" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "report_status") == :builtin
      assert Catalog.classify(catalog, "report_result") == :builtin
    end

    test "classifies subagent" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer")
      kit = %Kit{name: "test", agents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "reviewer") == :subagent
    end

    test "classifies module_skill from activated skills" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)

      skill = make_skill("scheduler:schedule")
      assert Catalog.classify(catalog, "schedule", [skill]) == {:module_skill, skill}
    end

    test "classifies tool as default" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "bash") == :tool
    end
  end

  # =====================================================================
  # dynamic updates
  # =====================================================================

  describe "dynamic updates" do
    test "adding skill to provider is reflected in next list_skills call" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:first"))

      catalog = start_catalog(provider)
      assert length(Catalog.list_skills(catalog)) == 1

      Memory.put(provider, make_skill("ns:second"))
      assert length(Catalog.list_skills(catalog)) == 2
    end
  end

  # =====================================================================
  # provider failure
  # =====================================================================

  describe "provider failure" do
    test "returns partial results when one provider fails" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:hello"))

      extra = [{FailingProvider, []}]
      catalog = start_catalog(provider, extra_providers: extra)

      skills = Catalog.list_skills(catalog)
      assert skills == [{"ns:hello", "ns:hello skill"}]
    end
  end
end
