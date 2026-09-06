defmodule SkillKit.Eval.CostTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval.Cost

  @usage %{
    input_tokens: 1_000_000,
    output_tokens: 1_000_000,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0
  }

  @zero %{
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0
  }

  describe "price/2" do
    test "prices usage at the model's rate, resolving a model URI to its id" do
      # 1M input @ $3 + 1M output @ $15 = $18
      assert_in_delta Cost.price(@usage, "anthropic://claude-sonnet-4-6"), 18.0, 1.0e-9
    end

    test "zero usage costs nothing even for a model with no known rate" do
      assert Cost.price(@zero, "mock://whatever") == 0.0
    end

    test "real usage on a model with no known rate is unpriceable (nil)" do
      assert Cost.price(@usage, "mock://whatever") == nil
    end
  end

  describe "total/1" do
    test "sums each component priced at its own model" do
      agent = {@usage, "anthropic://claude-sonnet-4-6"}
      # 1M input @ $1 + 1M output @ $5 = $6
      judge = {@usage, "anthropic://claude-haiku-4-5"}

      assert_in_delta Cost.total([agent, judge]), 24.0, 1.0e-9
    end

    test "is nil when any component is unpriceable" do
      priced = {@usage, "anthropic://claude-sonnet-4-6"}
      unpriced = {@usage, "mock://x"}

      assert Cost.total([priced, unpriced]) == nil
    end

    test "treats zero-usage components as free rather than unpriceable" do
      priced = {@usage, "anthropic://claude-sonnet-4-6"}
      skipped = {@zero, "mock://x"}

      assert_in_delta Cost.total([priced, skipped]), 18.0, 1.0e-9
    end
  end

  describe "format/1" do
    test "renders a dollar amount" do
      assert Cost.format(0.0135) == "$0.0135"
    end

    test "renders an unknown cost" do
      assert Cost.format(nil) == "cost unknown"
    end
  end
end
