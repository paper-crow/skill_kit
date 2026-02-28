defmodule SkillKit.RegistryTest do
  use ExUnit.Case, async: true

  alias SkillKit.{Registry, Skill}

  setup do
    name = :"registry_#{:erlang.unique_integer([:positive])}"
    registry = start_supervised!({Registry, name: name})
    %{registry: registry}
  end

  # ---------------------------------------------------------------------------
  # get_skill/2
  # ---------------------------------------------------------------------------

  describe "get_skill/2" do
    test "returns {:error, :not_found} for unknown skill", %{registry: registry} do
      assert {:error, :not_found} = Registry.get_skill(registry, "unknown:skill")
    end

    test "returns {:ok, skill} after registration", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)
      assert {:ok, ^skill} = Registry.get_skill(registry, "files:read")
    end
  end

  # ---------------------------------------------------------------------------
  # register/2 — success
  # ---------------------------------------------------------------------------

  describe "register/2 success" do
    test "register and get_skill round-trip returns same struct", %{registry: registry} do
      skill = %Skill{name: "tools:web-search", namespace: "tools"}
      assert :ok = Registry.register(registry, skill)
      assert {:ok, ^skill} = Registry.get_skill(registry, "tools:web-search")
    end

    test "overwrites on duplicate registration — returns latest skill", %{registry: registry} do
      skill_v1 = %Skill{name: "files:read", namespace: "files"}
      skill_v2 = %Skill{name: "files:read", namespace: "files"}

      assert :ok = Registry.register(registry, skill_v1)
      assert :ok = Registry.register(registry, skill_v2)
      assert {:ok, ^skill_v2} = Registry.get_skill(registry, "files:read")
    end

    test "accepts names with hyphens and underscores", %{registry: registry} do
      skill = %Skill{name: "my-org:analyze_data", namespace: "my-org"}
      assert :ok = Registry.register(registry, skill)
      assert {:ok, ^skill} = Registry.get_skill(registry, "my-org:analyze_data")
    end

    test "accepts names with digits (not at start)", %{registry: registry} do
      skill = %Skill{name: "tools2:skill3", namespace: "tools2"}
      assert :ok = Registry.register(registry, skill)
      assert {:ok, ^skill} = Registry.get_skill(registry, "tools2:skill3")
    end
  end

  # ---------------------------------------------------------------------------
  # register/2 — namespace validation
  # ---------------------------------------------------------------------------

  describe "register/2 namespace validation" do
    test "rejects name with no colon", %{registry: registry} do
      skill = %Skill{name: "badname", namespace: ""}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects multi-level namespace (a:b:c)", %{registry: registry} do
      skill = %Skill{name: "a:b:c", namespace: "a"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects empty namespace segment (:name)", %{registry: registry} do
      skill = %Skill{name: ":name", namespace: ""}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects empty skill name segment (ns:)", %{registry: registry} do
      skill = %Skill{name: "ns:", namespace: "ns"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects uppercase namespace (Tools:Read)", %{registry: registry} do
      skill = %Skill{name: "Tools:Read", namespace: "Tools"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects uppercase skill name (tools:Read)", %{registry: registry} do
      skill = %Skill{name: "tools:Read", namespace: "tools"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects name starting with digit (1tools:skill)", %{registry: registry} do
      skill = %Skill{name: "1tools:skill", namespace: "1tools"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects name starting with digit in skill part (tools:1skill)", %{registry: registry} do
      skill = %Skill{name: "tools:1skill", namespace: "tools"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "rejects name with special characters", %{registry: registry} do
      skill = %Skill{name: "tools:read!", namespace: "tools"}
      assert {:error, :invalid_namespace} = Registry.register(registry, skill)
    end

    test "does not store rejected skill", %{registry: registry} do
      skill = %Skill{name: "badname", namespace: ""}
      {:error, :invalid_namespace} = Registry.register(registry, skill)
      assert {:error, :not_found} = Registry.get_skill(registry, "badname")
    end
  end

  # ---------------------------------------------------------------------------
  # unregister/2
  # ---------------------------------------------------------------------------

  describe "unregister/2" do
    test "removes a registered skill", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)

      assert :ok = Registry.unregister(registry, "files:read")
      assert {:error, :not_found} = Registry.get_skill(registry, "files:read")
    end

    test "is idempotent — returns :ok for non-existent skill", %{registry: registry} do
      assert :ok = Registry.unregister(registry, "nonexistent:skill")
    end

    test "is idempotent — double unregister returns :ok", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)

      assert :ok = Registry.unregister(registry, "files:read")
      assert :ok = Registry.unregister(registry, "files:read")
    end
  end

  # ---------------------------------------------------------------------------
  # list_skills/1 and list_skills/2
  # ---------------------------------------------------------------------------

  describe "list_skills" do
    test "returns empty list when no skills registered", %{registry: registry} do
      assert [] = Registry.list_skills(registry)
    end

    test "returns all registered skills", %{registry: registry} do
      skill1 = %Skill{name: "files:read", namespace: "files"}
      skill2 = %Skill{name: "tools:search", namespace: "tools"}

      :ok = Registry.register(registry, skill1)
      :ok = Registry.register(registry, skill2)

      result = Registry.list_skills(registry)
      assert length(result) == 2
      assert skill1 in result
      assert skill2 in result
    end

    test "filters by exact namespace match", %{registry: registry} do
      skill1 = %Skill{name: "files:read", namespace: "files"}
      skill2 = %Skill{name: "files:write", namespace: "files"}
      skill3 = %Skill{name: "tools:search", namespace: "tools"}

      :ok = Registry.register(registry, skill1)
      :ok = Registry.register(registry, skill2)
      :ok = Registry.register(registry, skill3)

      result = Registry.list_skills(registry, namespace: "files")
      assert length(result) == 2
      assert skill1 in result
      assert skill2 in result
      refute skill3 in result
    end

    test "returns empty list when no skills match namespace filter", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)

      assert [] = Registry.list_skills(registry, namespace: "unknown")
    end

    test "exact namespace match — does not match prefix", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)

      # "file" is a prefix of "files" — should not match
      assert [] = Registry.list_skills(registry, namespace: "file")
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrent reads
  # ---------------------------------------------------------------------------

  describe "concurrent reads" do
    test "50 simultaneous reads complete without GenServer bottleneck", %{registry: registry} do
      skill = %Skill{name: "files:read", namespace: "files"}
      :ok = Registry.register(registry, skill)

      tasks =
        for _ <- 1..50 do
          Task.async(fn -> Registry.get_skill(registry, "files:read") end)
        end

      results = Task.await_many(tasks, 1_000)

      assert length(results) == 50
      assert Enum.all?(results, fn result -> result == {:ok, skill} end)
    end
  end
end
