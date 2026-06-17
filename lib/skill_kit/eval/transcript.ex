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

  @type t :: %__MODULE__{
          response: String.t() | nil,
          tool_calls: [String.t()],
          error: term(),
          status: status()
        }

  defstruct response: nil, tool_calls: [], error: nil, status: :pending
end
