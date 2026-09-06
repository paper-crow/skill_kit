defmodule SkillKit.Eval.Cost do
  @moduledoc """
  Derives the USD cost of an eval run from its token usage.

  An eval run has two priced components — the agent under test and the LLM
  judge — each with its own token usage and (possibly different) model. This
  module resolves each model URI to the id `SkillKit.LLM.Pricing` keys on,
  prices each component, and combines them.

  A component with no tokens is free regardless of its model, so a skipped
  judge never makes a run unpriceable. A component with real usage on a model
  with no known rate is genuinely unknown, so `total/1` reports `nil` rather
  than an understated figure.
  """

  alias SkillKit.Eval.Transcript
  alias SkillKit.Event.Usage
  alias SkillKit.LLM
  alias SkillKit.LLM.Pricing

  @type component :: {Transcript.usage(), String.t() | nil}

  @doc """
  Prices `usage` at `model`'s rate. Returns `0.0` for zero usage, the USD cost
  for a model with a known rate, or `nil` when a non-empty usage has no rate.
  """
  @spec price(Transcript.usage(), String.t() | nil) :: float() | nil
  def price(usage, model) do
    if empty?(usage), do: 0.0, else: Pricing.cost(struct(Usage, usage), model_id(model))
  end

  @doc """
  Sums the cost of each `{usage, model}` component. Returns `nil` when any
  component with real usage can't be priced.
  """
  @spec total([component()]) :: float() | nil
  def total(components) do
    components
    |> Enum.map(fn {usage, model} -> price(usage, model) end)
    |> combine()
  end

  @doc "Renders a cost as a dollar amount, or `\"cost unknown\"` for `nil`."
  @spec format(float() | nil) :: String.t()
  def format(nil), do: "cost unknown"
  def format(cost) when is_float(cost), do: "$" <> :erlang.float_to_binary(cost, decimals: 4)

  # Reuse the canonical model-URI resolution — it yields the same bare model id
  # a provider keys on (and the provider), so pricing never re-parses URIs.
  defp model_id(model), do: resolve(LLM.get_provider_and_opts(model))
  defp resolve({:ok, _provider, opts}), do: Keyword.get(opts, :model)
  defp resolve({:error, _reason}), do: nil

  defp combine(prices) do
    if Enum.any?(prices, &is_nil/1), do: nil, else: Enum.sum(prices)
  end

  defp empty?(usage) do
    usage.input_tokens == 0 and usage.output_tokens == 0 and
      usage.cache_creation_input_tokens == 0 and usage.cache_read_input_tokens == 0
  end
end
