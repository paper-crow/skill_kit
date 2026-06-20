defmodule SkillKit.LLM.PricingTest do
  use ExUnit.Case, async: true

  alias SkillKit.Event.Usage
  alias SkillKit.LLM.Pricing

  test "prices input and output tokens for a known model" do
    usage = %Usage{input_tokens: 1_000_000, output_tokens: 1_000_000}
    # 1M input @ $3 + 1M output @ $15 = $18
    assert_in_delta Pricing.cost(usage, "claude-sonnet-4-6"), 18.0, 1.0e-9
  end

  test "weights cache reads at 0.1x and cache writes at 1.25x the input rate" do
    read = %Usage{cache_read_input_tokens: 1_000_000}
    assert_in_delta Pricing.cost(read, "claude-sonnet-4-6"), 0.3, 1.0e-9

    write = %Usage{cache_creation_input_tokens: 1_000_000}
    assert_in_delta Pricing.cost(write, "claude-sonnet-4-6"), 3.75, 1.0e-9
  end

  test "unknown model returns nil" do
    assert Pricing.cost(%Usage{input_tokens: 100}, "gpt-5") == nil
  end
end
