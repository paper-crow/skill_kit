defmodule SkillKit.CredentialProviderTest do
  use ExUnit.Case, async: true

  alias SkillKit.CredentialProvider

  defp agent, do: %SkillKit.Agent{name: "test", description: "t", system_prompt: "s"}

  describe "default (null) implementation" do
    test "list/2 returns an empty list" do
      assert CredentialProvider.list(SkillKit.Tools.Shell, agent()) == []
    end

    test "fetch/3 returns {:ok, nil} for any key" do
      assert CredentialProvider.fetch(SkillKit.Tools.Shell, agent(), "GITHUB_TOKEN") ==
               {:ok, nil}
    end

    test "fetch/3 returns {:ok, nil} regardless of tool module" do
      assert CredentialProvider.fetch(SomeOtherTool, agent(), "X") == {:ok, nil}
    end
  end
end
