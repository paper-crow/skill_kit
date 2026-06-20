defmodule SkillKit.LLM.Anthropic do
  @moduledoc """
  Anthropic adapter for `SkillKit.LLM`.

  Sensitive config (api_key, endpoint) is resolved from opts first (for
  direct test calls), then app config, then env vars. Request params
  (model, max_tokens, temperature) are read from opts.

  ## Prompt caching

  Prompt caching is **on by default**. Two cache breakpoints are placed on
  every request:

  1. **System prompt breakpoint** — added to the last block of the system
     prompt, caching the tool list and system content together (the longest
     stable prefix).
  2. **Last-message breakpoint** — added to the final user message,
     providing a rolling cache that captures the conversation history up to
     that turn.

  Because caching is a byte-exact prefix match, the system prompt and tool
  list must be byte-identical across requests for cache reads to occur — keep
  the tool set and its ordering stable across calls.

  ### Disabling caching

  Add to `config/config.exs` (or an environment-specific config):

      config :skill_kit, SkillKit.LLM.Anthropic, cache: false

  Alternatively, pass `cache: false` in the opts to `stream/2` directly.

  ### TTL

  The default cache TTL is `"5m"` (5 minutes, Anthropic's standard tier).
  To use the extended 1-hour TTL (requires the `prompt_caching_2024_07_31`
  beta on your account):

      config :skill_kit, SkillKit.LLM.Anthropic, cache_ttl: "1h"

  Or pass `cache_ttl: "1h"` in opts.
  """

  @behaviour SkillKit.LLM

  alias SkillKit.Event.Streamable
  alias SkillKit.LLM.Anthropic.Encoder

  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 8096
  @default_endpoint "https://api.anthropic.com"

  @impl true
  def stream(messages, opts) do
    api_key = Keyword.get(opts, :api_key) || resolve_api_key()
    endpoint = Keyword.get(opts, :endpoint, resolve_endpoint())
    config = [api_key: api_key, endpoint: endpoint]

    {encoded_messages, request_opts} = build_request(messages, opts)

    case Anthropic.stream(config, encoded_messages, request_opts) do
      {:ok, stream} -> {:ok, to_skill_kit_stream(stream)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds the encoded messages and request options for an Anthropic call,
  applying prompt-cache breakpoints unless `cache: false`.

  Returns `{encoded_messages, request_opts}`.
  """
  @spec build_request([SkillKit.LLM.message()], keyword()) :: {[map()], keyword()}
  def build_request(messages, opts) do
    {cache?, opts} = Keyword.pop(opts, :cache, true)
    {cache_ttl, opts} = Keyword.pop(opts, :cache_ttl, "5m")
    {tools, opts} = Keyword.pop(opts, :tools, [])
    {params, opts} = Keyword.pop(opts, :params, %{})
    {system, opts} = Keyword.pop(opts, :system)

    encoded_messages =
      messages
      |> Encoder.encode_messages()
      |> maybe_cache_messages(cache?, cache_ttl)

    request_opts =
      opts
      |> Keyword.drop([:api_key, :endpoint])
      |> merge_params(params)
      |> maybe_put_tools(Encoder.encode_tools(tools))
      |> maybe_put_system(maybe_cache_system(system, cache?, cache_ttl))
      |> Keyword.put_new(:model, @default_model)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    {encoded_messages, request_opts}
  end

  defp maybe_cache_messages(messages, true, ttl), do: Encoder.cache_last_message(messages, ttl)
  defp maybe_cache_messages(messages, false, _ttl), do: messages

  defp maybe_cache_system(system, true, ttl), do: Encoder.cache_system(system, ttl)
  defp maybe_cache_system(system, false, _ttl), do: system

  defp maybe_put_tools(opts, []), do: opts
  defp maybe_put_tools(opts, tools), do: Keyword.put(opts, :tools, tools)

  defp maybe_put_system(opts, nil), do: opts
  defp maybe_put_system(opts, system), do: Keyword.put(opts, :system, system)

  # Merge the resolver's opaque model-URI query map into request opts.
  # Only the params Anthropic accepts are picked up — keyed by literal atoms,
  # so URI input is never atomized — and coerced to the JSON types its API
  # expects. Unrecognized params are dropped.
  defp merge_params(opts, params) do
    Enum.reduce(params, opts, fn {key, value}, acc -> put_param(acc, key, value) end)
  end

  defp put_param(opts, "max_tokens", value), do: Keyword.put(opts, :max_tokens, to_integer(value))
  defp put_param(opts, "temperature", value), do: Keyword.put(opts, :temperature, to_float(value))
  defp put_param(opts, "top_p", value), do: Keyword.put(opts, :top_p, to_float(value))
  defp put_param(opts, _key, _value), do: opts

  defp to_integer(value), do: parsed(Integer.parse(value), value)
  defp to_float(value), do: parsed(Float.parse(value), value)

  defp parsed({number, ""}, _raw), do: number
  defp parsed(_unparsed, raw), do: raw

  defp to_skill_kit_stream(anthropic_stream) do
    Stream.transform(anthropic_stream, %{blocks: %{}, partial_json: %{}}, &Streamable.stream/2)
  end

  defp resolve_api_key do
    config = Application.get_env(:skill_kit, __MODULE__, [])
    Keyword.get(config, :api_key) || System.get_env("ANTHROPIC_API_KEY")
  end

  defp resolve_endpoint do
    config = Application.get_env(:skill_kit, __MODULE__, [])
    Keyword.get(config, :endpoint, @default_endpoint)
  end
end
