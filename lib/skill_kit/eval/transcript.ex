defmodule SkillKit.Eval.Transcript do
  @moduledoc """
  The observable result of running an eval's prompt through an agent.

  Captures the final assistant response, the names of tools the agent called
  (in call order), and the terminal `:status` of the run:

    * `:ok` — the agent produced an assistant message
    * `:error` — the agent emitted an error event (`:reason` is set)
    * `:timeout` — no terminal event arrived before the deadline
    * `:pending` — initial state, before any events were collected
  """

  @type status :: :pending | :ok | :error | :timeout

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }

  @type t :: %__MODULE__{
          response: String.t() | nil,
          tool_calls: [String.t()],
          error: term(),
          status: status(),
          usage: usage()
        }

  @empty_usage %{
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0
  }

  defstruct response: nil, tool_calls: [], error: nil, status: :pending, usage: @empty_usage
end
