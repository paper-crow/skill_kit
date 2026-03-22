defmodule SkillKit.HookTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hook

  describe "Hook struct" do
    test "has phase, matcher, and handler fields" do
      hook = %Hook{}
      assert Map.has_key?(hook, :phase)
      assert Map.has_key?(hook, :matcher)
      assert Map.has_key?(hook, :handler)
    end

    test "all fields default to nil" do
      hook = %Hook{}
      assert is_nil(hook.phase)
      assert is_nil(hook.matcher)
      assert is_nil(hook.handler)
    end

    test "can be constructed with all fields" do
      hook = %Hook{
        phase: :pre,
        matcher: ~r/Shell/,
        handler: fn _ctx -> :allow end
      }

      assert hook.phase == :pre
      assert %Regex{} = hook.matcher
      assert hook.matcher.source == "Shell"
      assert is_function(hook.handler)
    end

    test "supports MFA handler tuple" do
      hook = %Hook{
        phase: :post,
        matcher: ~r/Shell/,
        handler: {MyModule, :my_function, []}
      }

      assert hook.handler == {MyModule, :my_function, []}
    end
  end
end
