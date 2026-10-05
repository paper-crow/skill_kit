defmodule SkillKit.CatalogTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent
  alias SkillKit.Catalog
  alias SkillKit.Hook
  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Tools.SendMessage
  alias SkillKit.Tools.Shell

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
    tools = Keyword.get(opts, :tools, [])
    extra_providers = Keyword.get(opts, :extra_providers, [])
    skills = [{Memory, provider: provider} | extra_providers]
    start_supervised!({Catalog, tools: tools, skills: skills, scope: scope})
  end

  defp make_skill(name, opts \\ []) do
    %Skill{
      name: name,
      description: Keyword.get(opts, :description, "#{name} skill"),
      body: Keyword.get(opts, :body, "do the thing"),
      tool: Keyword.get(opts, :tool, Shell),
      required_scope: Keyword.get(opts, :required_scope, []),
      hooks: Keyword.get(opts, :hooks, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp make_agent(name, opts \\ []) do
    %Agent{
      name: name,
      description: Keyword.get(opts, :description, "#{name} agent"),
      system_prompt: "You are #{name}."
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
      kit = %Kit{name: "test", subagents: [agent]}
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
      kit = %Kit{name: "test", subagents: [agent]}
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
  # agent
  # =====================================================================

  describe "agent/1" do
    test "returns agent when set" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("main")
      kit = %Kit{name: "test", agent: agent}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      result = Catalog.agent(catalog)
      assert result.name == "main"
    end

    test "returns nil when no agent" do
      {:ok, provider} = Memory.start_link([])
      Memory.put(provider, make_skill("ns:hello"))

      catalog = start_catalog(provider)
      assert Catalog.agent(catalog) == nil
    end
  end

  # =====================================================================
  # hooks
  # =====================================================================

  describe "list_hooks/2" do
    test "returns hooks from skills matching the given event" do
      {:ok, provider} = Memory.start_link([])
      hook = %Hook{event: :pre_tool_use, matcher: ~r/Shell/, handler: fn _ -> :ok end}
      Memory.put(provider, make_skill("ns:hooked", hooks: [hook]))

      catalog = start_catalog(provider)
      hooks = Catalog.list_hooks(catalog, :pre_tool_use)
      assert length(hooks) == 1
      assert hd(hooks).event == :pre_tool_use
    end

    test "returns empty list when no hooks match the given event" do
      {:ok, provider} = Memory.start_link([])
      hook = %Hook{event: :pre_tool_use, matcher: ~r/Shell/, handler: fn _ -> :ok end}
      Memory.put(provider, make_skill("ns:hooked", hooks: [hook]))

      catalog = start_catalog(provider)
      assert Catalog.list_hooks(catalog, :post_tool_use) == []
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

    test "includes agent tools" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer", description: "Reviews code")
      kit = %Kit{name: "test", subagents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      tools = Catalog.tool_definitions(catalog, [])

      agent_tool = Enum.find(tools, &(&1.name == "reviewer"))
      assert agent_tool != nil
      assert agent_tool.input_schema["properties"]["task"] != nil
      assert agent_tool.input_schema["required"] == ["task"]
    end

    test "includes tool definitions from tool providers" do
      {:ok, provider} = Memory.start_link([])

      kit = %Kit{
        name: "shell_kit",
        skills: [],
        metadata: %{tool: Shell}
      }

      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider, tools: [{Memory, provider: provider}])
      tools = Catalog.tool_definitions(catalog, [])

      tool_def = Enum.find(tools, &(&1.name == Shell.definition().name))
      assert tool_def != nil
    end

    test "includes kits that use SkillKit.Kit without overriding load_kits" do
      {:ok, provider} = Memory.start_link([])

      catalog = start_catalog(provider, tools: [{SendMessage, []}])
      tools = Catalog.tool_definitions(catalog, [])

      assert Enum.any?(tools, &(&1.name == SendMessage.definition().name))

      assert Catalog.tool_config(catalog, SendMessage.definition().name) ==
               {SendMessage, %{tool: SendMessage}}
    end
  end

  # =====================================================================
  # classify
  # =====================================================================

  describe "classify/2" do
    test "classifies activate_skill" do
      {:ok, provider} = Memory.start_link([])
      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "activate_skill") == :activate_skill
    end

    test "classifies subagent" do
      {:ok, provider} = Memory.start_link([])
      agent = make_agent("reviewer")
      kit = %Kit{name: "test", subagents: [agent]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "reviewer") == :subagent
    end

    test "does not classify shell skills without activation" do
      {:ok, provider} = Memory.start_link([])
      skill = make_skill("ns:run")
      kit = %Kit{name: "ns", skills: [skill]}
      Memory.put_kit(provider, kit)

      catalog = start_catalog(provider)
      assert Catalog.classify(catalog, "run") == :tool
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
