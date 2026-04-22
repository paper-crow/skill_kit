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

  describe "register/2 + get/2 + unregister/2" do
    setup do
      name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
      {:ok, _pid} = SkillKit.Webhook.Supervisor.start_link(name: name)
      {:ok, supervisor: name}
    end

    test "register stores the webhook, get retrieves it, unregister removes it",
         %{supervisor: sup} do
      webhook = %Webhook{
        id: "abc",
        agent_name: "a",
        prompt: "hi",
        verifier: {SomeMod, %{}},
        inserted_at: DateTime.utc_now()
      }

      assert :ok = Webhook.register(webhook, supervisor: sup)
      assert {:ok, ^webhook} = Webhook.get("abc", supervisor: sup)
      assert :ok = Webhook.unregister("abc", supervisor: sup)
      assert {:error, :not_found} = Webhook.get("abc", supervisor: sup)
    end

    test "list/2 returns everything when filter is empty", %{supervisor: sup} do
      w1 = %Webhook{
        id: "1",
        agent_name: "x",
        prompt: "",
        verifier: {M, %{}},
        inserted_at: DateTime.utc_now()
      }

      w2 = %Webhook{
        id: "2",
        agent_name: "y",
        prompt: "",
        verifier: {M, %{}},
        inserted_at: DateTime.utc_now()
      }

      Webhook.register(w1, supervisor: sup)
      Webhook.register(w2, supervisor: sup)

      assert {:ok, webhooks} = Webhook.list(%{}, supervisor: sup)
      assert length(webhooks) == 2
    end

    test "list/2 filters by agent_name", %{supervisor: sup} do
      Webhook.register(
        %Webhook{
          id: "1",
          agent_name: "x",
          prompt: "",
          verifier: {M, %{}},
          inserted_at: DateTime.utc_now()
        },
        supervisor: sup
      )

      assert {:ok, [%Webhook{agent_name: "x"}]} =
               Webhook.list(%{agent_name: "x"}, supervisor: sup)
    end
  end
end
