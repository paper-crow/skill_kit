defmodule SkillKit.Tools.WebhookTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.ToolExecution
  alias SkillKit.Tools.Webhook, as: WebhookKit
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.Stripe

  setup :verify_on_exit!

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: name)
    {:ok, supervisor: name}
  end

  defp exec(operation, input, supervisor) do
    %ToolExecution{
      tool: WebhookKit,
      input: Map.put(input, "operation", operation),
      context: %{
        supervisor: supervisor,
        verifiers: %{"stripe" => Stripe},
        agent_name: "kit-agent",
        agent: %SkAgent{name: "kit-agent", description: "", system_prompt: ""}
      }
    }
  end

  describe "execute/1 :: register" do
    test "rejects unknown verifier type", %{supervisor: sup} do
      input = %{"prompt" => "p", "verifier" => %{"type" => "ghost", "secret_key" => "X"}}
      assert {:error, msg} = WebhookKit.execute(exec("register", input, sup))
      assert msg =~ "unknown verifier"
    end

    test "rejects missing secret_key", %{supervisor: sup} do
      input = %{"prompt" => "p", "verifier" => %{"type" => "stripe"}}
      assert {:error, msg} = WebhookKit.execute(exec("register", input, sup))
      assert msg =~ "secret_key"
    end

    test "creates a webhook record and returns the URL", %{supervisor: sup} do
      input = %{
        "prompt" => "Stripe: $WEBHOOK_BODY",
        "verifier" => %{"type" => "stripe", "secret_key" => "STRIPE"}
      }

      assert {:ok, reply} = WebhookKit.execute(exec("register", input, sup))
      assert reply =~ "Webhook registered. URL:"

      assert {:ok,
              [
                %Webhook{
                  prompt: "Stripe: $WEBHOOK_BODY",
                  verifier: {Stripe, %{secret_key: "STRIPE"}}
                }
              ]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end
  end

  describe "execute/1 :: unregister" do
    test "removes by id", %{supervisor: sup} do
      {:ok, _} =
        WebhookKit.execute(
          exec(
            "register",
            %{"prompt" => "p", "verifier" => %{"type" => "stripe", "secret_key" => "S"}},
            sup
          )
        )

      [%Webhook{id: id}] = fetch_webhooks(sup)
      assert {:ok, "OK"} = WebhookKit.execute(exec("unregister", %{"id" => id}, sup))
      assert [] = fetch_webhooks(sup)
    end
  end

  describe "execute/1 :: list" do
    test "returns compact JSON array", %{supervisor: sup} do
      WebhookKit.execute(
        exec(
          "register",
          %{"prompt" => "p", "verifier" => %{"type" => "stripe", "secret_key" => "S"}},
          sup
        )
      )

      assert {:ok, reply} = WebhookKit.execute(exec("list", %{}, sup))
      assert {:ok, list} = Jason.decode(reply)
      assert length(list) == 1

      assert [
               %{
                 "prompt" => "p",
                 "verifier" => %{"type" => "Elixir.SkillKit.Webhook.Verifier.Stripe"}
               }
             ] = list
    end
  end

  defp fetch_webhooks(sup) do
    {:ok, list} = Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    list
  end
end
