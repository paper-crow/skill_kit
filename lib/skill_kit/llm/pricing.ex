defmodule SkillKit.LLM.Pricing do
  @moduledoc """
  Derives USD cost from token usage and a model id.

  Per-million-token input/output rates are stored per model. Cache rates
  are properties of the caching mechanism, not the model, so they are
  applied as multipliers on the input rate: cache reads cost 0.1x input,
  and cache writes cost 1.25x input (the 5-minute TTL rate). The rarer
  1-hour TTL write rate (2x) is not modeled here; reads dominate cost, so
  the resulting estimate error is negligible. Unknown models return `nil`.
  """

  alias SkillKit.Event.Usage

  @million 1_000_000
  @cache_read_multiplier 0.1
  @cache_write_multiplier 1.25

  # USD per million tokens.
  @rates %{
    "claude-sonnet-4-6" => %{input: 3.0, output: 15.0},
    "claude-haiku-4-5" => %{input: 1.0, output: 5.0},
    "claude-opus-4-8" => %{input: 5.0, output: 25.0}
  }

  @doc "Returns the USD cost of `usage` for `model`, or `nil` for an unknown model."
  @spec cost(Usage.t(), String.t()) :: float() | nil
  def cost(%Usage{} = usage, model) do
    case Map.fetch(@rates, model) do
      {:ok, rate} -> compute(usage, rate)
      :error -> nil
    end
  end

  defp compute(usage, rate) do
    input = usage.input_tokens * rate.input
    output = usage.output_tokens * rate.output
    cache_write = usage.cache_creation_input_tokens * rate.input * @cache_write_multiplier
    cache_read = usage.cache_read_input_tokens * rate.input * @cache_read_multiplier
    (input + output + cache_write + cache_read) / @million
  end
end
