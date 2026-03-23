defmodule SkillKit.LLM.Anthropic do
  @moduledoc """
  Anthropic adapter for `SkillKit.LLM`.

  Translates native `SkillKit.LLM.Message` structs to Anthropic API
  format via the encoder, delegates streaming to the `Anthropic` client.
  Response decoding is left to the caller — the stream returns raw
  SSE events that can be decoded via `SkillKit.LLM.Anthropic.Decoder`.
  """

  @behaviour SkillKit.LLM

  alias SkillKit.LLM.Anthropic.Encoder

  @default_model "claude-sonnet-4-20250514"

  @impl true
  def stream(config, messages, opts) do
    encoded_messages = Encoder.encode_messages(messages)
    {tools, opts} = Keyword.pop(opts, :tools, [])
    encoded_tools = Encoder.encode_tools(tools)
    opts = if encoded_tools != [], do: Keyword.put(opts, :tools, encoded_tools), else: opts
    opts = if Keyword.get(opts, :model), do: opts, else: Keyword.put(opts, :model, @default_model)
    Anthropic.stream(config, encoded_messages, opts)
  end
end
