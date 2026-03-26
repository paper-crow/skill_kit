defmodule SkillKit.SkillTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill

  defmodule TestScope do
    defstruct [:user]
  end

  defimpl SkillKit.Scope, for: TestScope do
    def permissions(_scope), do: []
    def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
    def resolve(_scope, _key, _context), do: :error
  end

  describe "Skill struct" do
    test "has expected fields" do
      skill = %Skill{}
      assert Map.has_key?(skill, :name)
      assert Map.has_key?(skill, :namespace)
      assert Map.has_key?(skill, :description)
      assert Map.has_key?(skill, :body)
      assert Map.has_key?(skill, :location)
      assert Map.has_key?(skill, :required_scope)
      assert Map.has_key?(skill, :tool)
      assert Map.has_key?(skill, :hooks)
    end

    test "does not have removed fields" do
      skill = %Skill{}
      refute Map.has_key?(skill, :type)
      refute Map.has_key?(skill, :module)
      refute Map.has_key?(skill, :source)
    end

    test "required_scope defaults to empty list" do
      assert %Skill{}.required_scope == []
    end

    test "tool defaults to SkillKit.Tools.Shell" do
      assert %Skill{}.tool == SkillKit.Tools.Shell
    end

    test "hooks defaults to empty list" do
      assert %Skill{}.hooks == []
    end

    test "nil-defaulting fields default to nil" do
      skill = %Skill{}
      assert is_nil(skill.name)
      assert is_nil(skill.namespace)
      assert is_nil(skill.description)
      assert is_nil(skill.body)
      assert is_nil(skill.location)
    end
  end

  describe "render/2" do
    test "substitutes $ARGUMENTS with all arguments" do
      skill = %Skill{body: "Fix issue $ARGUMENTS"}
      assert {:ok, "Fix issue 123"} = Skill.render(skill, %{"arguments" => "123"})
    end

    test "substitutes $ARGUMENTS[N] with positional args" do
      skill = %Skill{body: "Migrate $ARGUMENTS[0] from $ARGUMENTS[1]"}
      args = %{"arguments" => "SearchBar React"}
      assert {:ok, "Migrate SearchBar from React"} = Skill.render(skill, args)
    end

    test "substitutes $N shorthand for positional args" do
      skill = %Skill{body: "Migrate $0 from $1 to $2"}
      args = %{"arguments" => "SearchBar React Vue"}
      assert {:ok, "Migrate SearchBar from React to Vue"} = Skill.render(skill, args)
    end

    test "substitutes ${CLAUDE_SKILL_DIR} with skill location directory" do
      skill = %Skill{
        body: "Run ${CLAUDE_SKILL_DIR}/scripts/build.sh",
        location: "/home/user/.agents/skills/builder/SKILL.md"
      }

      assert {:ok, "Run /home/user/.agents/skills/builder/scripts/build.sh"} =
               Skill.render(skill, %{})
    end

    test "substitutes ${CLAUDE_SESSION_ID} from args" do
      skill = %Skill{body: "Log to ${CLAUDE_SESSION_ID}.log"}
      args = %{"session_id" => "abc-123"}
      assert {:ok, "Log to abc-123.log"} = Skill.render(skill, args)
    end

    test "returns body unchanged when no substitution tokens present" do
      skill = %Skill{body: "No tokens here."}
      assert {:ok, "No tokens here."} = Skill.render(skill, %{})
    end

    test "appends ARGUMENTS when $ARGUMENTS not in body but arguments provided" do
      skill = %Skill{body: "Do the thing"}
      args = %{"arguments" => "with this input"}
      assert {:ok, "Do the thing\n\nARGUMENTS: with this input"} = Skill.render(skill, args)
    end

    test "returns body as-is when no arguments and no tokens" do
      skill = %Skill{body: "Just instructions"}
      assert {:ok, "Just instructions"} = Skill.render(skill, %{})
    end

    test "returns {:ok, empty string} when body is nil" do
      skill = %Skill{body: nil}
      assert {:ok, ""} = Skill.render(skill, %{})
    end

    test "does not append ARGUMENTS when body contains $0 shorthand" do
      skill = %Skill{body: "Process $0"}
      args = %{"arguments" => "file.txt"}
      assert {:ok, "Process file.txt"} = Skill.render(skill, args)
    end
  end

  describe "render/3 with unified syntax" do
    test "substitutes $SKILL_DIR (new name for ${CLAUDE_SKILL_DIR})" do
      skill = %Skill{body: "Run $SKILL_DIR/build.sh", location: "/skills/builder/SKILL.md"}
      assert {:ok, "Run /skills/builder/build.sh"} = Skill.render(skill, %{})
    end

    test "substitutes ${SKILL_DIR} with braces" do
      skill = %Skill{body: "Run ${SKILL_DIR}/build.sh", location: "/skills/builder/SKILL.md"}
      assert {:ok, "Run /skills/builder/build.sh"} = Skill.render(skill, %{})
    end

    test "substitutes $SESSION_ID (new name for ${CLAUDE_SESSION_ID})" do
      skill = %Skill{body: "Log to $SESSION_ID.log"}
      assert {:ok, "Log to abc-123.log"} = Skill.render(skill, %{"session_id" => "abc-123"})
    end

    test "resolves unmatched variables via scope" do
      skill = %Skill{name: "memory_kit:user_memory", body: "Hello $USERNAME"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "pirate_pete", skill: "memory_kit:user_memory"}
      assert {:ok, "Hello alice"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "scope resolution works with braces syntax" do
      skill = %Skill{name: "memory_kit:user_memory", body: "Hello ${USERNAME}"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "pirate_pete", skill: "memory_kit:user_memory"}
      assert {:ok, "Hello alice"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "unresolved scope variables are left as-is" do
      skill = %Skill{name: "test:skill", body: "Value is $UNKNOWN"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "test", skill: "test:skill"}
      assert {:ok, "Value is $UNKNOWN"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "$ARGUMENTS takes precedence over scope variables" do
      skill = %Skill{name: "test:skill", body: "User: $ARGUMENTS"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "test", skill: "test:skill"}

      assert {:ok, "User: bob"} =
               Skill.render(skill, %{"arguments" => "bob"}, scope, scope_context)
    end

    test "render/2 without scope still works (backwards compatible)" do
      skill = %Skill{body: "Fix issue $ARGUMENTS"}
      assert {:ok, "Fix issue 123"} = Skill.render(skill, %{"arguments" => "123"})
    end
  end

  describe "dynamic command injection (!`command`)" do
    test "executes command and substitutes output" do
      skill = %Skill{body: "Today is !`echo hello`"}
      assert {:ok, "Today is hello"} = Skill.render(skill, %{})
    end

    test "handles multiple commands" do
      skill = %Skill{body: "A: !`echo one` B: !`echo two`"}
      assert {:ok, "A: one B: two"} = Skill.render(skill, %{})
    end

    test "shows error for failed commands" do
      skill = %Skill{body: "Result: !`exit 1`"}
      assert {:ok, "Result: [command failed: ]"} = Skill.render(skill, %{})
    end

    test "command output is subject to variable substitution" do
      skill = %Skill{body: "Count: !`echo 3` files with $ARGUMENTS"}
      assert {:ok, "Count: 3 files with hello"} = Skill.render(skill, %{"arguments" => "hello"})
    end

    test "body without commands is unchanged" do
      skill = %Skill{body: "No commands here"}
      assert {:ok, "No commands here"} = Skill.render(skill, %{})
    end
  end
end
