defmodule SkillKit.WebhookTest do
  use ExUnit.Case, async: true

  alias SkillKit.Webhook

  describe "%Webhook{}" do
    test "defaults idempotency to nil" do
      now = DateTime.utc_now()

      assert %Webhook{
               id: "id-1",
               agent_name: "agent",
               prompt: "hi",
               verifier: {SomeModule, %{}},
               idempotency: nil,
               inserted_at: ^now
             } =
               %Webhook{
                 id: "id-1",
                 agent_name: "agent",
                 prompt: "hi",
                 verifier: {SomeModule, %{}},
                 inserted_at: now
               }
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Webhook, id: "id-1")
      end
    end
  end
end
