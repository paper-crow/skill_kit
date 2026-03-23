defmodule SkillKit.LLM.MetadataTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Metadata

  describe "extract_backend/1" do
    test "extracts provider, model, and max_tokens from skill_kit: prefixed keys" do
      metadata = %{
        "skill_kit:backend:provider" => "anthropic",
        "skill_kit:backend:model" => "claude-sonnet-4-20250514",
        "skill_kit:backend:max-tokens" => "4096"
      }

      assert {:ok, {SkillKit.LLM.Anthropic, opts}} = Metadata.extract_backend(metadata)
      assert opts[:model] == "claude-sonnet-4-20250514"
      assert opts[:max_tokens] == 4096
    end

    test "returns :default when no skill_kit:backend keys present" do
      assert :default = Metadata.extract_backend(%{})
    end

    test "returns :default when metadata is nil" do
      assert :default = Metadata.extract_backend(nil)
    end

    test "ignores non-skill_kit keys" do
      metadata = %{
        "author" => "someone",
        "skill_kit:backend:provider" => "anthropic"
      }

      assert {:ok, {SkillKit.LLM.Anthropic, _opts}} = Metadata.extract_backend(metadata)
    end

    test "returns error for unknown provider" do
      metadata = %{"skill_kit:backend:provider" => "unknown_provider"}

      assert {:error, {:unknown_provider, "unknown_provider"}} =
               Metadata.extract_backend(metadata)
    end

    test "extracts temperature as float" do
      metadata = %{
        "skill_kit:backend:provider" => "anthropic",
        "skill_kit:backend:temperature" => "0.7"
      }

      assert {:ok, {SkillKit.LLM.Anthropic, opts}} = Metadata.extract_backend(metadata)
      assert opts[:temperature] == 0.7
    end
  end
end
