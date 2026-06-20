defmodule SkillKit.Stream do
  @moduledoc """
  Lazy stream of agent events from the caller's mailbox.

  When an agent is started with `caller: self()`, the caller process
  receives a stream of structs as the turn unfolds (`%Event.Delta{}`,
  `%Event.ToolCallComplete{}`, `%Types.AssistantMessage{}`,
  `%Event.Error{}`, ...). `stream/2` exposes that as an `Enumerable`
  so rendering, broadcasting, filtering, etc. compose via the
  standard library's `Stream.*` and `Enum.*`:

      agent.name
      |> SkillKit.Stream.stream()
      |> Stream.each(&print/1)
      |> Enum.reduce(:timeout, fn event, _ -> event end)
      |> case do
        %AssistantMessage{} = msg -> {:ok, msg}
        %Event.Error{reason: reason} -> {:error, reason}
        :timeout -> {:error, :timeout}
      end
  """

  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Types.AssistantMessage

  @default_timeout 60_000

  @doc """
  Returns a lazy `Enumerable` of events from the caller's mailbox for
  one turn of `agent_name`.

  The stream emits every event reaching the caller (including
  sub-loops) in arrival order, and ends when:

    * the *root* agent's `%AssistantMessage{}` or `%Event.Error{}`
      arrives — it is emitted as the final element; or
    * the per-receive timeout elapses with no new event — no further
      element is emitted.

  Sub-loop terminal events flow through like any other event and do
  not end the stream.

  Must be called from the process registered as `:caller` in
  `SkillKit.start_agent/2`.

  ## Options

    * `:timeout` — ms to wait for the next event, or `:infinity`
      (default: `#{@default_timeout}`).
  """
  @spec stream(String.t(), keyword()) :: Enumerable.t()
  def stream(agent_name, opts \\ []) when is_binary(agent_name) do
    opts = Keyword.validate!(opts, timeout: @default_timeout)
    timeout = opts[:timeout]

    Stream.unfold(:running, &pull(&1, agent_name, timeout))
  end

  defp pull(:done, _agent_name, _timeout), do: nil

  defp pull(:running, agent_name, timeout) do
    receive do
      %AssistantMessage{agent: ^agent_name} = msg -> {msg, :done}
      %EventError{agent: ^agent_name} = err -> {err, :done}
      event -> {event, :running}
    after
      timeout -> nil
    end
  end
end
