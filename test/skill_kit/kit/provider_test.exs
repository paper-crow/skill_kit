defmodule SkillKit.Kit.ProviderTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Provider

  test "Provider module defines load_kits/1 callback" do
    assert {:load_kits, 1} in Provider.behaviour_info(:callbacks)
  end
end
