defmodule SkillKit.HookTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hook

  describe "Hook struct" do
    test "has event, matcher, and handler fields" do
      hook = %Hook{}
      assert Map.has_key?(hook, :event)
      assert Map.has_key?(hook, :matcher)
      assert Map.has_key?(hook, :handler)
    end

    test "all fields default to nil" do
      hook = %Hook{}
      assert is_nil(hook.event)
      assert is_nil(hook.matcher)
      assert is_nil(hook.handler)
    end

    test "can be constructed with function handler" do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: fn _ctx -> :ok end
      }

      assert hook.event == :pre_tool_use
      assert %Regex{} = hook.matcher
      assert is_function(hook.handler)
    end

    test "supports MFA handler tuple" do
      hook = %Hook{
        event: :post_tool_use,
        matcher: ~r/Shell/,
        handler: {MyModule, :my_function, []}
      }

      assert hook.handler == {MyModule, :my_function, []}
    end

    test "supports {module, config} handler tuple" do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: {SomeHandler, %{"command" => "true"}}
      }

      assert {SomeHandler, %{"command" => "true"}} = hook.handler
    end
  end
end
