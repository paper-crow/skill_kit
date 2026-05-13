defmodule Mix.Tasks.SkillKit.DemoTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.SkillKit.Demo

  setup do
    prev = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prev) end)
    :ok
  end

  test "errors and exits with code 1 when no prompt is provided" do
    assert catch_exit(Demo.run([])) == {:shutdown, 1}
    assert_received {:mix_shell, :error, [usage]}
    assert usage =~ "Usage:"
  end
end
