if Mix.env() == :test do
  defmodule SkillKit.Test do
    @moduledoc """
    Test helpers for SkillKit.

    Provides Mox convenience helpers for testing agents and LLM interactions.
    Provider-specific event builders live in their own modules
    (e.g., `Anthropic.Test`).

    ## Setup

        use SkillKit.Test

    This imports `SkillKit.Test` and sets up `Mox.verify_on_exit!/1`.
    """

    alias SkillKit.Agent.Definition
    alias SkillKit.Agent.Server
    alias SkillKit.Response.Error

    defmacro __using__(_opts) do
      quote do
        import SkillKit.Test
        setup :verify_on_exit!
      end
    end

    @doc """
    Starts a bare Server process for unit testing.

    Returns `{:ok, server_pid, context}` where context contains `:registry`,
    `:agent_name`, and `:definition`.
    """
    @spec start_server(keyword()) :: {:ok, pid(), map()}
    def start_server(opts \\ []) do
      agent_name =
        Keyword.get(opts, :agent_name, "test-agent-#{:erlang.unique_integer([:positive])}")

      caller = Keyword.get(opts, :caller, self())
      scope = Keyword.get(opts, :scope)
      skills = Keyword.get(opts, :skills, [])

      definition =
        Keyword.get_lazy(opts, :definition, fn ->
          %Definition{
            name: agent_name,
            description: "Test agent",
            system_prompt: "You are a test agent.",
            path: "/tmp/test"
          }
        end)

      registry_name = :"test_registry_#{:erlang.unique_integer([:positive])}"
      ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: registry_name})

      ExUnit.Callbacks.start_supervised!(
        {SkillKit.Catalog,
         name: {:via, Registry, {registry_name, {agent_name, :catalog}}},
         providers: skills,
         scope: scope}
      )

      server_opts = [caller: caller, skills: skills]

      {:ok, pid} =
        Server.start_link({agent_name, definition, 0, nil, scope, registry_name, server_opts})

      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      context = %{registry: registry_name, agent_name: agent_name, definition: definition}
      {:ok, pid, context}
    end

    @doc """
    Sets up a single Mox expectation that returns the given response.
    """
    @spec expect_response(struct()) :: :ok
    def expect_response(response) do
      Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
        build_event_stream(response)
      end)

      :ok
    end

    @doc """
    Sets up a Mox expectation that runs the assertion callback, then returns the response.

    The callback receives `(messages, opts)` — the arguments the LLM mock was called with.
    """
    @spec assert_response(struct(), (list(), keyword() -> any())) :: :ok
    def assert_response(response, assertion_fn) do
      Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn messages, opts ->
        assertion_fn.(messages, opts)
        build_event_stream(response)
      end)

      :ok
    end

    @doc """
    Sets up multi-call Mox expectations from a list of response types.

    Each element corresponds to one `LLM.stream` call in order.
    """
    @spec expect_responses([struct()]) :: :ok
    def expect_responses(responses) do
      count = length(responses)
      counter = :counters.new(1, [:atomics])
      responses_list = :lists.zip(:lists.seq(1, count), responses)
      responses_map = Map.new(responses_list)

      Mox.expect(SkillKit.LLM.Mock, :stream, count, fn _messages, _opts ->
        index = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, index)
        build_event_stream(Map.fetch!(responses_map, index))
      end)

      :ok
    end

    @doc """
    Sets up a Mox expectation returning an LLM error.
    """
    @spec expect_error(integer(), String.t()) :: :ok
    def expect_error(status, message) do
      expect_response(%Error{status: status, message: message})
    end

    defp build_event_stream(%SkillKit.Response.Text{content: text}) do
      events = [
        %SkillKit.Event.Delta{text: text},
        %SkillKit.Event.Done{stop_reason: :end_turn}
      ]

      {:ok, Stream.map(events, & &1)}
    end

    defp build_event_stream(%SkillKit.Response.ToolCall{name: name, input: input}) do
      id = "tc_test_#{:erlang.unique_integer([:positive])}"

      events = [
        %SkillKit.Event.ToolCallStart{id: id, name: name},
        %SkillKit.Event.ToolCallComplete{id: id, name: name, input: input},
        %SkillKit.Event.Done{stop_reason: :tool_use}
      ]

      {:ok, Stream.map(events, & &1)}
    end

    defp build_event_stream(%SkillKit.Response.Empty{}) do
      events = [%SkillKit.Event.Done{stop_reason: :end_turn}]
      {:ok, Stream.map(events, & &1)}
    end

    defp build_event_stream(%SkillKit.Response.Error{status: status, message: message}) do
      {:error, {status, message}}
    end
  end
end
