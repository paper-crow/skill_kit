defmodule Anthropic.Event do
  @moduledoc false

  alias Anthropic.Event.ContentBlockDelta
  alias Anthropic.Event.ContentBlockStart
  alias Anthropic.Event.ContentBlockStop
  alias Anthropic.Event.MessageDelta
  alias Anthropic.Event.MessageStart
  alias Anthropic.Event.MessageStop

  @spec parse(map()) :: struct() | :skip
  def parse(%{"type" => "message_start", "message" => msg}) do
    %MessageStart{id: msg["id"], usage: msg["usage"]}
  end

  def parse(%{"type" => "content_block_start", "index" => idx, "content_block" => cb}) do
    %ContentBlockStart{index: idx, content_block: parse_content_block(cb)}
  end

  def parse(%{"type" => "content_block_delta", "index" => idx, "delta" => delta}) do
    %ContentBlockDelta{index: idx, delta: parse_delta(delta)}
  end

  def parse(%{"type" => "content_block_stop", "index" => idx}) do
    %ContentBlockStop{index: idx}
  end

  def parse(%{"type" => "message_delta", "delta" => delta} = event) do
    %MessageDelta{
      stop_reason: parse_stop_reason(delta["stop_reason"]),
      usage: event["usage"] || delta["usage"]
    }
  end

  def parse(%{"type" => "message_stop"}) do
    %MessageStop{}
  end

  def parse(%{"type" => "ping"}), do: :skip
  def parse(_other), do: :skip

  defp parse_content_block(%{"type" => "text"} = cb) do
    %{type: :text, text: cb["text"]}
  end

  defp parse_content_block(%{"type" => "tool_use"} = cb) do
    %{type: :tool_use, id: cb["id"], name: cb["name"]}
  end

  defp parse_delta(%{"type" => "text_delta"} = d), do: %{type: :text_delta, text: d["text"]}

  defp parse_delta(%{"type" => "input_json_delta"} = d),
    do: %{type: :input_json_delta, partial_json: d["partial_json"]}

  defp parse_delta(d), do: d

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason(other), do: other
end
