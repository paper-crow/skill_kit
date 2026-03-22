defmodule Anthropic.Client do
  @moduledoc """
  Struct holding Anthropic API connection configuration.

  Used by `Anthropic.stream/3` to build HTTP requests. Struct-based
  so tests can pass config directly without global state.
  """

  @default_endpoint "https://api.anthropic.com"

  @type t :: %__MODULE__{
          api_key: String.t(),
          endpoint: String.t()
        }

  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    endpoint: @default_endpoint
  ]

  @doc "Creates a new client from a keyword list. `:api_key` is required."
  @spec new(keyword()) :: t()
  def new(opts) do
    _ = Keyword.fetch!(opts, :api_key)
    struct!(__MODULE__, opts)
  end
end
