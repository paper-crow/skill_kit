defmodule SkillKit.SkillTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill

  # ---------------------------------------------------------------------------
  # Struct field verification
  # ---------------------------------------------------------------------------

  describe "Skill struct" do
    test "has all 8 expected fields" do
      skill = %Skill{}
      assert Map.has_key?(skill, :type)
      assert Map.has_key?(skill, :name)
      assert Map.has_key?(skill, :namespace)
      assert Map.has_key?(skill, :description)
      assert Map.has_key?(skill, :required_scope)
      assert Map.has_key?(skill, :module)
      assert Map.has_key?(skill, :body)
      assert Map.has_key?(skill, :source)
    end

    test "required_scope defaults to empty list" do
      skill = %Skill{}
      assert skill.required_scope == []
    end

    test "all other fields default to nil" do
      skill = %Skill{}
      assert is_nil(skill.type)
      assert is_nil(skill.name)
      assert is_nil(skill.namespace)
      assert is_nil(skill.description)
      assert is_nil(skill.module)
      assert is_nil(skill.body)
      assert is_nil(skill.source)
    end
  end

  # ---------------------------------------------------------------------------
  # execute/3 dispatch — code skills
  # ---------------------------------------------------------------------------

  describe "execute/3 for :code skills" do
    test "dispatches to module.execute/2 and returns its result" do
      skill = %Skill{type: :code, module: SkillKit.TestSkills.Echo}
      assert {:ok, %{"text" => "hello"}} = Skill.execute(skill, %{"text" => "hello"}, %{})
    end

    test "passes args and context to module.execute/2" do
      skill = %Skill{type: :code, module: SkillKit.TestSkills.Echo}
      args = %{"key" => "value", "count" => 42}
      assert {:ok, ^args} = Skill.execute(skill, args, %{})
    end

    test "returns {:ok, result} from module with empty args" do
      skill = %Skill{type: :code, module: SkillKit.TestSkills.Echo}
      assert {:ok, %{}} = Skill.execute(skill, %{}, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # execute/3 dispatch — prompt skills
  # ---------------------------------------------------------------------------

  describe "execute/3 for :prompt skills" do
    test "interpolates single {{var}} template" do
      skill = %Skill{type: :prompt, body: "Hello {{name}}"}
      assert {:ok, "Hello World"} = Skill.execute(skill, %{"name" => "World"}, %{})
    end

    test "interpolates multiple {{vars}} in one pass" do
      skill = %Skill{type: :prompt, body: "Hello {{name}}, welcome to {{place}}!"}

      assert {:ok, "Hello Alice, welcome to Wonderland!"} =
               Skill.execute(skill, %{"name" => "Alice", "place" => "Wonderland"}, %{})
    end

    test "returns body as-is when no {{vars}} present" do
      skill = %Skill{type: :prompt, body: "No template vars here."}
      assert {:ok, "No template vars here."} = Skill.execute(skill, %{}, %{})
    end

    test "returns {:error, {:missing_arg, name}} when template var is absent" do
      skill = %Skill{type: :prompt, body: "Hello {{missing}}"}
      assert {:error, {:missing_arg, "missing"}} = Skill.execute(skill, %{}, %{})
    end

    test "fails fast on missing arg when multiple vars present" do
      skill = %Skill{type: :prompt, body: "{{a}} and {{b}}"}
      # Only provide :a — should fail on :b
      result = Skill.execute(skill, %{"a" => "present"}, %{})
      assert {:error, {:missing_arg, "b"}} = result
    end

    test "returns {:error, {:missing_arg, name}} with partial args (one present, one missing)" do
      skill = %Skill{type: :prompt, body: "{{present}} is here, {{absent}} is not"}

      assert {:error, {:missing_arg, "absent"}} =
               Skill.execute(skill, %{"present" => "yes"}, %{})
    end

    test "coerces non-string arg values to string" do
      skill = %Skill{type: :prompt, body: "Count: {{count}}"}
      assert {:ok, "Count: 42"} = Skill.execute(skill, %{"count" => 42}, %{})
    end

    test "ignores context argument for prompt skills" do
      skill = %Skill{type: :prompt, body: "Hello {{name}}"}
      # context is ignored for prompt skills
      assert {:ok, "Hello Test"} = Skill.execute(skill, %{"name" => "Test"}, %{"ctx" => "data"})
    end
  end

  # ---------------------------------------------------------------------------
  # Behaviour contract verification — compile-time coverage
  # ---------------------------------------------------------------------------

  describe "@behaviour SkillKit.Skill" do
    test "Echo module implements all 4 callbacks correctly" do
      assert SkillKit.TestSkills.Echo.name() == "test:echo"
      assert SkillKit.TestSkills.Echo.description() == "Echoes input"
      assert SkillKit.TestSkills.Echo.required_scope() == ["test:read"]
      assert {:ok, %{}} = SkillKit.TestSkills.Echo.execute(%{}, %{})
    end

    test "behaviour defines all 4 expected callbacks" do
      callbacks = SkillKit.Skill.behaviour_info(:callbacks)
      assert {:name, 0} in callbacks
      assert {:description, 0} in callbacks
      assert {:required_scope, 0} in callbacks
      assert {:execute, 2} in callbacks
    end
  end
end
