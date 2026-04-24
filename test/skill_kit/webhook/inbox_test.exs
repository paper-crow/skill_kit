defmodule SkillKit.Webhook.InboxTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Storage
  alias SkillKit.Webhook.Inbox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  defp entry(overrides) do
    delivery =
      Map.merge(
        %{
          id: "dlv_abc",
          webhook_id: "wh_xyz",
          agent_name: "dispatch-agent",
          received_at: DateTime.utc_now(),
          method: "POST",
          headers: %{"x-github-event" => "push"},
          query: %{},
          body: ~s({"ref":"main"})
        },
        Map.get(overrides, :delivery, %{})
      )

    %{
      agent: Map.get(overrides, :agent, nil),
      prompt: Map.get(overrides, :prompt, "Process this webhook."),
      delivery: delivery
    }
  end

  describe "compose/1" do
    test "returns pointer text + standard send_event opts" do
      {text, opts} = Inbox.compose(entry(%{prompt: "My intent"}))

      assert text =~ "<webhook-delivery"
      assert text =~ ~s(id="dlv_abc")
      assert text =~ ~s(webhook_id="wh_xyz")
      refute text =~ "My intent"

      assert Keyword.fetch!(opts, :system_append) == "My intent"
      assert [{SkillKit.Tools.WebhookInbox, ctx}] = Keyword.fetch!(opts, :tools_add)
      assert ctx.agent_name == "dispatch-agent"
      assert ctx.delivery_id == "dlv_abc"
      assert Keyword.fetch!(opts, :tools_remove) == [SkillKit.Tools.Webhook]
      assert Keyword.fetch!(opts, :skills_remove_prefix) == "webhook:"
      assert Keyword.fetch!(opts, :allow_activate_skill) == true
      assert Keyword.fetch!(opts, :initial_messages) == :empty
      assert Keyword.fetch!(opts, :sub_agent_name) =~ "dispatch-agent/delivery:wh_xyz"
    end
  end

  describe "dispatch/1" do
    test "returns {:error, :not_found} for a stopped agent" do
      name = "inbox-dispatch-dead-#{System.unique_integer([:positive])}"

      definition = %SkillKit.Agent{
        name: name,
        description: "Test",
        system_prompt: "Test",
        model: "test-model"
      }

      {:ok, agent_ref} = SkillKit.start_agent(definition)
      SkillKit.stop_agent(agent_ref)
      Process.sleep(50)

      e = entry(%{agent: agent_ref, delivery: %{agent_name: name}})

      assert {:error, :not_found} = Inbox.dispatch(e)
    end

    # Full dispatch → sub-loop → turn pair integration test lives in
    # test/skill_kit/webhook/integration_test.exs (needs WebhookInbox tool).
  end
end
