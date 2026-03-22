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

  @impl true
  def stream(config, messages, opts) do
    encoded = Encoder.encode_messages(messages)
    Anthropic.stream(config, encoded, opts)
  end
end
