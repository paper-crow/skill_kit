defmodule SkillKit.Agent.StreamAccumulatorTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.StreamAccumulator
  alias SkillKit.Event.Usage

  test "new/0 seeds all four usage fields at zero" do
    assert StreamAccumulator.new().usage == %{
             input_tokens: 0,
             output_tokens: 0,
             cache_creation_input_tokens: 0,
             cache_read_input_tokens: 0
           }
  end

  test "merge_usage/2 sums all four token fields" do
    base = StreamAccumulator.new().usage
    first = %Usage{input_tokens: 10, cache_read_input_tokens: 5}
    second = %Usage{output_tokens: 3, cache_creation_input_tokens: 2, cache_read_input_tokens: 5}

    merged =
      base
      |> StreamAccumulator.merge_usage(first)
      |> StreamAccumulator.merge_usage(second)

    assert merged == %{
             input_tokens: 10,
             output_tokens: 3,
             cache_creation_input_tokens: 2,
             cache_read_input_tokens: 10
           }
  end
end
