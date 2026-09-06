defmodule SkillKit.E2ETest do
  @moduledoc """
  End-to-end tests that hit a real LLM provider.

  These tests cover the message flow patterns from the runtime abstraction
  design spec and verify telemetry events fire correctly. Excluded by
  default — run with:

      LLM_PROVIDER=anthropic mix test --include e2e

  The tests are provider-agnostic. Adding a new provider means adding an
  entry to `@providers` — the tests themselves don't change.
  """
  use ExUnit.Case, async: false

  import SkillKit.TelemetryHelper

  alias SkillKit.Event.Delta
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Kit.Local
  alias SkillKit.Storage
  alias SkillKit.Types.AssistantMessage

  @moduletag :e2e
  @timeout 30_000

  @providers %{
    "anthropic" => %{
      model: "anthropic://claude-sonnet-4-20250514",
      env: "ANTHROPIC_API_KEY"
    }
  }

  @fixtures_disk Path.expand("../support/fixtures/e2e", __DIR__)
  @worker_kit_path Path.join(@fixtures_disk, "worker_kit")

  setup :telemetry

  setup do
    provider = System.get_env("LLM_PROVIDER")

    if provider in [nil, ""] do
      flunk("LLM_PROVIDER is required. Usage: LLM_PROVIDER=anthropic mix test --include e2e")
    end

    config =
      Map.get(@providers, provider) ||
        flunk(
          "Unknown provider #{inspect(provider)}. " <>
            "Known: #{@providers |> Map.keys() |> Enum.join(", ")}"
        )

    api_key = System.get_env(config.env)

    if api_key in [nil, ""] do
      flunk("#{config.env} is required for #{provider} e2e tests")
    end

    start_supervised!(Storage.Memory)
    seed_fixture_tree(@fixtures_disk, @fixtures_disk)

    {:ok, model: config.model}
  end

  # ---------------------------------------------------------------------------
  # Single-turn text response
  # ---------------------------------------------------------------------------

  describe "single-turn conversation" do
    @tag telemetry: [
           [:skill_kit, :turn, :stop],
           [:skill_kit, :llm_request, :stop],
           [:skill_kit, :llm, :stream, :stop]
         ]
    test "streams deltas and returns a complete response", %{model: model} do
      agent =
        start_e2e_agent!(
          "e2e-text",
          "Always respond with exactly: SKILLKIT_ECHO_TEST. Nothing else, ever.",
          model: model
        )

      :ok = SkillKit.send_message(agent, "hello")

      assert_receive %AssistantMessage{content: content}, @timeout
      assert content =~ "SKILLKIT_ECHO_TEST"
      assert_received %Delta{text: _}

      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: "e2e-text"}}
      assert_receive {__MODULE__, [:skill_kit, :llm_request, :stop], %{agent_name: "e2e-text"}}
      assert_receive {__MODULE__, [:skill_kit, :llm, :stream, :stop], _}
    end
  end

  # ---------------------------------------------------------------------------
  # Tool use round-trip
  # ---------------------------------------------------------------------------

  describe "tool use round-trip" do
    @tag telemetry: [
           [:skill_kit, :turn, :stop],
           [:skill_kit, :tool_use, :stop],
           [:skill_kit, :tool_batch, :start],
           [:skill_kit, :tool_batch, :stop],
           [:skill_kit, :llm_request, :stop]
         ]
    test "agent calls bash tool, receives result, and responds", %{model: model} do
      agent =
        start_e2e_agent!(
          "e2e-tool",
          """
          You have a bash tool. When asked, run the exact command given.
          After getting the result, reply with only the command output, nothing else.
          """,
          model: model,
          skills: [SkillKit.Tools.Shell]
        )

      :ok = SkillKit.send_message(agent, "Run: echo skillkit-e2e-ok")

      assert_receive %ToolCallComplete{name: "bash"}, @timeout
      assert_receive %AssistantMessage{content: content}, @timeout
      assert content =~ "skillkit-e2e-ok"

      assert_receive {__MODULE__, [:skill_kit, :tool_batch, :start],
                      %{agent_name: "e2e-tool", tool_count: 1, tool_names: ["bash"]}}

      assert_receive {__MODULE__, [:skill_kit, :tool_batch, :stop], %{agent_name: "e2e-tool"}}
      assert_receive {__MODULE__, [:skill_kit, :tool_use, :stop], %{agent_name: "e2e-tool"}}

      # Two LLM requests: first returns tool call, second returns text
      assert_receive {__MODULE__, [:skill_kit, :llm_request, :stop], %{agent_name: "e2e-tool"}}
      assert_receive {__MODULE__, [:skill_kit, :llm_request, :stop], %{agent_name: "e2e-tool"}}

      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: "e2e-tool"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Simple delegation (Pattern 1) — parent delegates to subagent
  # ---------------------------------------------------------------------------

  describe "simple delegation (Pattern 1)" do
    @tag telemetry: [
           [:skill_kit, :turn, :stop],
           [:skill_kit, :subagent, :stop],
           [:skill_kit, :tool_batch, :stop]
         ]
    test "parent delegates to subagent, receives result via natural completion", %{model: model} do
      agent =
        start_e2e_agent!(
          "e2e-delegator",
          """
          You are an orchestrator. You have a subagent called "worker".
          When asked to delegate, call the worker subagent with the exact task given.
          After the worker completes, reply with the worker's result prefixed by "RESULT: ".
          """,
          model: model,
          skills: [{Local, dir: @worker_kit_path}],
          max_agent_depth: 2
        )

      :ok =
        SkillKit.send_message(
          agent,
          "Delegate this task to the worker: respond with exactly WORKER_OK"
        )

      # The parent may respond multiple times (once before subagent completes,
      # once after). Wait for the one containing the worker's result.
      assert_receive_match(AssistantMessage, &(&1.content =~ "WORKER_OK"), 60_000)

      assert_receive {__MODULE__, [:skill_kit, :subagent, :stop], %{agent_name: "e2e-delegator"}}

      assert_receive {__MODULE__, [:skill_kit, :tool_batch, :stop],
                      %{agent_name: "e2e-delegator"}}

      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: "e2e-delegator"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-turn conversation — LLM asks clarifying question
  # ---------------------------------------------------------------------------

  describe "multi-turn clarification" do
    @tag telemetry: [
           [:skill_kit, :turn, :stop],
           [:skill_kit, :tool_use, :stop],
           [:skill_kit, :tool_batch, :stop]
         ]
    test "LLM asks for missing info, user provides it, tool executes", %{model: model} do
      agent =
        start_e2e_agent!(
          "e2e-multi",
          """
          You have a bash tool. The user will ask you to echo text.
          You MUST have the exact text before running the tool — never guess.
          If the user says to echo something without providing the text, ask:
          "What text should I echo?"
          Once you have the text, run: echo <text>
          Reply with only the command output.
          """,
          model: model,
          skills: [SkillKit.Tools.Shell]
        )

      # Turn 1: no text provided, LLM must ask
      :ok = SkillKit.send_message(agent, "I need you to echo some text for me")

      assert_receive %AssistantMessage{content: clarification}, @timeout
      assert clarification =~ ~r/[Ww]hat.*text|[Ww]hat.*echo|[Ww]hich.*text/

      # Turn 2: user provides the text, LLM calls the tool
      :ok = SkillKit.send_message(agent, "skillkit-multi-turn-ok")

      assert_receive %ToolCallComplete{name: "bash"}, @timeout
      assert_receive %AssistantMessage{content: content}, @timeout
      assert content =~ "skillkit-multi-turn-ok"

      # tool_batch and tool_use fire on the second turn
      assert_receive {__MODULE__, [:skill_kit, :tool_batch, :stop], %{agent_name: "e2e-multi"}}
      assert_receive {__MODULE__, [:skill_kit, :tool_use, :stop], %{agent_name: "e2e-multi"}}

      # Two turns fired
      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: "e2e-multi"}}
      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: "e2e-multi"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_e2e_agent!(name, system_prompt, opts) do
    {skills, opts} = Keyword.pop(opts, :skills, [])
    {max_depth, opts} = Keyword.pop(opts, :max_agent_depth, 1)
    {model, _opts} = Keyword.pop(opts, :model)

    definition = %SkillKit.Agent{
      name: name,
      description: "E2E test agent",
      system_prompt: system_prompt,
      model: model,
      max_agent_depth: max_depth
    }

    {:ok, agent} =
      SkillKit.start_agent(definition,
        skills: skills,
        caller: self()
      )

    on_exit(fn ->
      try do
        SkillKit.stop_agent(agent)
      catch
        :exit, _ -> :ok
      end
    end)

    agent
  end

  # Waits for a struct of the given module where the predicate returns true.
  # Uses selective receive — only consumes matching structs, leaves other
  # messages (telemetry events, deltas, etc.) in the mailbox.
  defp assert_receive_match(struct_mod, predicate, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_until_match(struct_mod, predicate, deadline)
  end

  defp receive_until_match(struct_mod, predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      %{__struct__: ^struct_mod} = msg ->
        if predicate.(msg), do: msg, else: receive_until_match(struct_mod, predicate, deadline)
    after
      remaining -> flunk("No matching #{inspect(struct_mod)} received within timeout")
    end
  end

  defp seed_fixture_tree(disk_path, storage_path) do
    Storage.ensure_dir!(storage_path)

    case File.ls(disk_path) do
      {:ok, entries} -> Enum.each(entries, &seed_entry(disk_path, storage_path, &1))
      {:error, _} -> :ok
    end
  end

  defp seed_entry(disk_path, storage_path, entry) do
    disk_entry = Path.join(disk_path, entry)
    storage_entry = Path.join(storage_path, entry)

    if File.dir?(disk_entry) do
      seed_fixture_tree(disk_entry, storage_entry)
    else
      {:ok, content} = File.read(disk_entry)
      Storage.put!(storage_entry, content)
    end
  end
end
