defmodule SkillKit.LLM.Anthropic do
  @moduledoc """
  Anthropic adapter for `SkillKit.LLM`.

  Sensitive config (api_key, endpoint) is resolved from opts first (for
  direct test calls), then app config, then env vars. Request params
  (model, max_tokens, temperature) are read from opts.
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

    encoded_messages = Encoder.encode_messages(messages)
    {tools, opts} = Keyword.pop(opts, :tools, [])
    encoded_tools = Encoder.encode_tools(tools)

    request_opts =
      opts
      |> Keyword.drop([:api_key, :endpoint])
      |> maybe_put_tools(encoded_tools)
      |> Keyword.put_new(:model, @default_model)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    case Anthropic.stream(config, encoded_messages, request_opts) do
      {:ok, stream} -> {:ok, to_skill_kit_stream(stream)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_tools(opts, []), do: opts
  defp maybe_put_tools(opts, tools), do: Keyword.put(opts, :tools, tools)

  defp to_skill_kit_stream(anthropic_stream) do
    Stream.transform(anthropic_stream, %{blocks: %{}, partial_json: %{}}, &Streamable.to_events/2)
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
