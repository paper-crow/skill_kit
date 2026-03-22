defmodule SkillKit.CatalogTest do
  use ExUnit.Case, async: true

  alias SkillKit.{Catalog, Skill}

  setup do
    name = :"registry_#{:erlang.unique_integer([:positive])}"
    _pid = start_supervised!({SkillKit.Registry, name: name})

    skill = %Skill{
      name: "files:read",
      namespace: "files",
      description: "Read files",
      body: "Read $ARGUMENTS",
      required_scope: ["files:read"]
    }

    open_skill = %Skill{
      name: "test:open",
      namespace: "test",
      description: "No auth needed",
      body: "Open stuff"
    }

    SkillKit.Registry.register(name, skill)
    SkillKit.Registry.register(name, open_skill)

    %{catalog: name}
  end

  describe "list_skills/2" do
    test "returns only authorized skills when scopes provided", %{catalog: cat} do
      skills = Catalog.list_skills(cat, scopes: ["files:read"])
      names = Enum.map(skills, & &1.name)
      assert "files:read" in names
      assert "test:open" in names
    end

    test "filters out skills the caller lacks scopes for", %{catalog: cat} do
      skills = Catalog.list_skills(cat, scopes: ["test:write"])
      names = Enum.map(skills, & &1.name)
      refute "files:read" in names
      assert "test:open" in names
    end

    test "returns all skills when no scopes option provided", %{catalog: cat} do
      skills = Catalog.list_skills(cat, [])
      assert length(skills) == 2
    end

    test "wildcard scope covers required scope", %{catalog: cat} do
      skills = Catalog.list_skills(cat, scopes: ["files:*"])
      names = Enum.map(skills, & &1.name)
      assert "files:read" in names
    end
  end

  describe "get_skill/3" do
    test "returns skill when authorized", %{catalog: cat} do
      assert {:ok, %Skill{name: "files:read"}} =
               Catalog.get_skill(cat, "files:read", scopes: ["files:*"])
    end

    test "returns {:error, :unauthorized} when lacking scope", %{catalog: cat} do
      assert {:error, :unauthorized} =
               Catalog.get_skill(cat, "files:read", scopes: ["test:read"])
    end

    test "returns {:error, :not_found} for nonexistent skill", %{catalog: cat} do
      assert {:error, :not_found} =
               Catalog.get_skill(cat, "nope:nope", scopes: ["admin:*"])
    end

    test "returns skill without auth check when no scopes option", %{catalog: cat} do
      assert {:ok, %Skill{name: "files:read"}} = Catalog.get_skill(cat, "files:read")
    end
  end

  describe "activate/4" do
    test "returns rendered body for authorized skill", %{catalog: cat} do
      assert {:ok, rendered} =
               Catalog.activate(cat, "files:read", %{"arguments" => "README.md"},
                 scopes: ["files:*"]
               )

      assert rendered == "Read README.md"
    end

    test "returns {:error, :unauthorized} when lacking scope", %{catalog: cat} do
      assert {:error, :unauthorized} =
               Catalog.activate(cat, "files:read", %{}, scopes: [])
    end

    test "returns {:error, :not_found} for nonexistent skill", %{catalog: cat} do
      assert {:error, :not_found} =
               Catalog.activate(cat, "nope:nope", %{}, scopes: ["admin:*"])
    end

    test "activates without auth check when no scopes option", %{catalog: cat} do
      assert {:ok, rendered} =
               Catalog.activate(cat, "test:open", %{}, [])

      assert rendered == "Open stuff"
    end
  end

  describe "register/2 and unregister/2" do
    test "register passes through to Registry", %{catalog: cat} do
      new_skill = %Skill{name: "new:skill", namespace: "new", description: "New", body: "Do new"}
      assert :ok = Catalog.register(cat, new_skill)
      assert {:ok, _} = Catalog.get_skill(cat, "new:skill")
    end

    test "unregister passes through to Registry", %{catalog: cat} do
      assert :ok = Catalog.unregister(cat, "files:read")
      assert {:error, :not_found} = Catalog.get_skill(cat, "files:read")
    end
  end
end
