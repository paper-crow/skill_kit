if Mix.env() == :test do
  defmodule SkillKit.Test.HookHandler do
    @moduledoc """
    Test hook handler that captures invocations and sends them to the test process.

    ## Usage

        start_supervised!({SkillKit.Test.HookHandler, test_pid: self()})

    Then register hooks with `{SkillKit.Test.HookHandler, config}` as the handler.
    Each invocation sends `{:hook_fired, config, context}` to the test process.

    Use the `"reply"` key in config to control the return value:

        %Hook{event: :pre_tool_use, handler: {SkillKit.Test.HookHandler, %{"reply" => {:deny, "no"}}}}
    """

    @behaviour SkillKit.Hooks.Handler
    use GenServer

    def start_link(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, test_pid, name: name)
    end

    @impl GenServer
    def init(test_pid) do
      {:ok, test_pid}
    end

    @impl SkillKit.Hooks.Handler
    def execute(config, context) do
      GenServer.call(__MODULE__, {:execute, config, context})
    end

    @impl GenServer
    def handle_call({:execute, config, context}, _from, test_pid) do
      send(test_pid, {:hook_fired, config, context})
      reply = Map.get(config, "reply", :ok)
      {:reply, reply, test_pid}
    end
  end
end
