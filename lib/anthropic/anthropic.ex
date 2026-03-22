defmodule Anthropic do
  @moduledoc """
  Public API for the Anthropic Messages client.

  Accepts a keyword config list, builds a `%Anthropic.Client{}`,
  and delegates to its streaming function. This module is the entry
  point for callers that have config as data (e.g. from application env).
  """

  alias Anthropic.Client

  @doc """
  Streams a chat completion from the Anthropic Messages API.

  `config` is a keyword list passed to `Anthropic.Client.new/1`.
  `messages` is the conversation history. `opts` are request options
  (`:model`, `:max_tokens`, `:system`, `:tools`, etc.).
  """
  @spec stream(keyword(), list(map()), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(config, messages, opts \\ []) do
    config
    |> Client.new()
    |> Client.stream(messages, opts)
  end
end
