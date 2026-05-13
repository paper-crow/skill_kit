defmodule SkillKit.Tools.WebhookTest do
  use ExUnit.Case, async: false

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.ToolExecution
  alias SkillKit.Tools.Webhook, as: WebhookKit
  alias SkillKit.Webhook
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Verifier.Github
  alias SkillKit.Webhook.Verifier.None
  alias SkillKit.Webhook.Verifier.Slack
  alias SkillKit.Webhook.Verifier.Stripe

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: name)
    {:ok, supervisor: name}
  end

  # -- definition ---------------------------------------------------------

  describe "definition/0" do
    test "tool name + description + input_schema surface" do
      assert %SkillKit.Tool{
               name: "webhook",
               description: description,
               input_schema: %{
                 "type" => "object",
                 "properties" => %{
                   "operation" => %{"enum" => ["register", "update", "unregister", "list"]},
                   "prompt" => %{"type" => "string"},
                   "idempotency" => %{"type" => "object"},
                   "id" => %{"type" => "string"}
                 },
                 "required" => ["operation"]
               }
             } = WebhookKit.definition()

      assert description =~ "Register, update, unregister, or list HTTP webhook endpoints"
      assert description =~ "URL discipline"
      assert description =~ "quote it\nverbatim from memory"
    end
  end

  # -- kit loading --------------------------------------------------------

  describe "load_kits/1" do
    test "loads signed vendor skills + management skills by default" do
      {:ok, [kit]} = WebhookKit.load_kits([])
      names = Enum.map(kit.skills, & &1.name)
      assert "webhook:github" in names
      assert "webhook:stripe" in names
      assert "webhook:slack" in names
      assert "webhook:update" in names
      assert "webhook:unregister" in names
      assert "webhook:list" in names
      refute "webhook:unsigned" in names
    end

    test "allow_unsigned: true adds the unsigned skill" do
      {:ok, [kit]} = WebhookKit.load_kits(allow_unsigned: true)
      names = Enum.map(kit.skills, & &1.name)
      assert "webhook:unsigned" in names
    end

    test "github skill carries verifier module + configured secret_key in metadata" do
      {:ok, [kit]} = WebhookKit.load_kits(github: [secret_key: "GH_KEY"])
      skill = Enum.find(kit.skills, &(&1.name == "webhook:github"))
      assert skill.metadata.verifier_module == Github
      assert skill.metadata.secret_key == "GH_KEY"
      assert skill.metadata.max_skew == 300
    end

    test "github skill without config is still loaded with nil secret_key" do
      {:ok, [kit]} = WebhookKit.load_kits([])
      skill = Enum.find(kit.skills, &(&1.name == "webhook:github"))
      assert skill.metadata.verifier_module == Github
      assert skill.metadata.secret_key == nil
    end

    test "stripe honors max_skew override" do
      {:ok, [kit]} =
        WebhookKit.load_kits(stripe: [secret_key: "STRIPE_KEY", max_skew: 600])

      skill = Enum.find(kit.skills, &(&1.name == "webhook:stripe"))
      assert skill.metadata.verifier_module == Stripe
      assert skill.metadata.secret_key == "STRIPE_KEY"
      assert skill.metadata.max_skew == 600
    end

    test "slack config recognized" do
      {:ok, [kit]} = WebhookKit.load_kits(slack: [secret_key: "SLACK_KEY"])
      skill = Enum.find(kit.skills, &(&1.name == "webhook:slack"))
      assert skill.metadata.verifier_module == Slack
      assert skill.metadata.secret_key == "SLACK_KEY"
    end

    test "unsigned skill carries Verifier.None with nil secret_key" do
      {:ok, [kit]} = WebhookKit.load_kits(allow_unsigned: true)
      skill = Enum.find(kit.skills, &(&1.name == "webhook:unsigned"))
      assert skill.metadata.verifier_module == None
      assert skill.metadata.secret_key == nil
    end

    test "raises on malformed vendor config" do
      assert_raise ArgumentError, fn ->
        WebhookKit.load_kits(github: [max_skew: 300])
      end
    end
  end

  # -- register -----------------------------------------------------------
  #
  # Registration always succeeds regardless of whether the vendor is
  # configured on the host. If the vendor's secret_key is nil, the
  # webhook is stored with a nil secret_key; the verifier errors with
  # :misconfigured at on-hit time, which the Plug handles as 500. The
  # LLM never sees the gap during registration — no drift pathway to
  # unsigned.

  describe "execute/1 :: register" do
    test "github registers with the host-configured secret_key", %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      assert {:ok, reply} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => "handle github push"},
                 context: ctx
               })

      assert reply =~ "Webhook registered. URL:"

      assert {:ok, [%Webhook{verifier: {Github, %{secret_key: "GH_KEY", max_skew: 300}}}]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end

    test "stripe registers with host-configured secret", %{supervisor: sup} do
      ctx = register_ctx("webhook:stripe", sup)

      assert {:ok, _} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => "handle stripe"},
                 context: ctx
               })

      assert {:ok, [%Webhook{verifier: {Stripe, %{secret_key: "STRIPE_KEY"}}}]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end

    test "slack registers with host-configured secret", %{supervisor: sup} do
      ctx = register_ctx("webhook:slack", sup)

      assert {:ok, _} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => "handle slack"},
                 context: ctx
               })

      assert {:ok, [%Webhook{verifier: {Slack, %{secret_key: "SLACK_KEY"}}}]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end

    test "unsigned registers with Verifier.None (no secret)", %{supervisor: sup} do
      ctx = register_ctx("webhook:unsigned", sup)

      assert {:ok, _} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => "handle ad-hoc"},
                 context: ctx
               })

      assert {:ok, [%Webhook{verifier: {None, %{}}}]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end

    test "unconfigured vendor still registers successfully (verifier fails at on-hit)",
         %{supervisor: sup} do
      # Host did NOT configure github; registration still succeeds from the
      # LLM's perspective. The webhook is stored with a nil secret_key.
      {:ok, [kit]} = WebhookKit.load_kits([])
      skill = Enum.find(kit.skills, &(&1.name == "webhook:github"))
      ctx = build_ctx(skill, sup)

      assert {:ok, reply} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => "p"},
                 context: ctx
               })

      assert reply =~ "Webhook registered. URL:"

      assert {:ok, [%Webhook{verifier: {Github, %{secret_key: nil}}}]} =
               Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    end

    test "errors on missing prompt", %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      assert {:error, msg} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register"},
                 context: ctx
               })

      assert msg =~ "prompt"
    end

    test "errors on empty prompt", %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      assert {:error, msg} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "register", "prompt" => ""},
                 context: ctx
               })

      assert msg =~ "prompt"
    end
  end

  # -- update (prompt-only) -----------------------------------------------

  describe "execute/1 :: update" do
    test "changes prompt while preserving verifier + id + agent_name",
         %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      {:ok, _} =
        WebhookKit.execute(%ToolExecution{
          tool: WebhookKit,
          input: %{"operation" => "register", "prompt" => "original"},
          context: ctx
        })

      [%Webhook{id: id, verifier: verifier, inserted_at: inserted_at}] = fetch_webhooks(sup)

      update_ctx = update_ctx(sup)

      assert {:ok, reply} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "update", "id" => id, "prompt" => "updated"},
                 context: update_ctx
               })

      assert reply =~ "Webhook updated. URL:"

      assert {:ok,
              %Webhook{
                id: ^id,
                agent_name: "kit-agent",
                prompt: "updated",
                verifier: ^verifier,
                inserted_at: ^inserted_at
              }} = Webhook.get(id, supervisor: sup)
    end

    test "verifier field in input is ignored (prompt-only update)",
         %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      {:ok, _} =
        WebhookKit.execute(%ToolExecution{
          tool: WebhookKit,
          input: %{"operation" => "register", "prompt" => "p"},
          context: ctx
        })

      [%Webhook{id: id, verifier: original}] = fetch_webhooks(sup)
      update_ctx = update_ctx(sup)

      WebhookKit.execute(%ToolExecution{
        tool: WebhookKit,
        input: %{
          "operation" => "update",
          "id" => id,
          "prompt" => "new prompt",
          "verifier" => %{"type" => "stripe", "secret_key" => "X"}
        },
        context: update_ctx
      })

      assert {:ok, %Webhook{verifier: ^original}} = Webhook.get(id, supervisor: sup)
    end

    test "errors when id is missing", %{supervisor: sup} do
      update_ctx = update_ctx(sup)

      assert {:error, "missing required field: id"} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "update", "prompt" => "x"},
                 context: update_ctx
               })
    end

    test "errors when prompt is missing — does not silently keep the existing prompt",
         %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      {:ok, _} =
        WebhookKit.execute(%ToolExecution{
          tool: WebhookKit,
          input: %{"operation" => "register", "prompt" => "original"},
          context: ctx
        })

      [%Webhook{id: id}] = fetch_webhooks(sup)
      update_ctx = update_ctx(sup)

      assert {:error, "missing required field: prompt"} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "update", "id" => id},
                 context: update_ctx
               })

      # And the original prompt is genuinely untouched on disk.
      assert {:ok, %Webhook{prompt: "original"}} = Webhook.get(id, supervisor: sup)
    end

    test "errors when id is unknown", %{supervisor: sup} do
      update_ctx = update_ctx(sup)

      assert {:error, msg} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "update", "id" => "ghost", "prompt" => "x"},
                 context: update_ctx
               })

      assert msg =~ "not found"
    end
  end

  # -- list + unregister --------------------------------------------------

  describe "execute/1 :: list" do
    test "returns registered webhooks as JSON", %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      {:ok, _} =
        WebhookKit.execute(%ToolExecution{
          tool: WebhookKit,
          input: %{"operation" => "register", "prompt" => "p"},
          context: ctx
        })

      list_ctx = update_ctx(sup)

      assert {:ok, reply} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "list"},
                 context: list_ctx
               })

      assert {:ok, [%{"prompt" => "p"}]} = Jason.decode(reply)
    end
  end

  describe "execute/1 :: unregister" do
    test "removes by id", %{supervisor: sup} do
      ctx = register_ctx("webhook:github", sup)

      {:ok, _} =
        WebhookKit.execute(%ToolExecution{
          tool: WebhookKit,
          input: %{"operation" => "register", "prompt" => "p"},
          context: ctx
        })

      [%Webhook{id: id}] = fetch_webhooks(sup)
      un_ctx = update_ctx(sup)

      assert {:ok, "OK"} =
               WebhookKit.execute(%ToolExecution{
                 tool: WebhookKit,
                 input: %{"operation" => "unregister", "id" => id},
                 context: un_ctx
               })

      assert [] = fetch_webhooks(sup)
    end
  end

  # -- helpers ------------------------------------------------------------

  defp register_ctx(skill_name, supervisor) do
    {:ok, [kit]} =
      WebhookKit.load_kits(
        github: [secret_key: "GH_KEY"],
        stripe: [secret_key: "STRIPE_KEY"],
        slack: [secret_key: "SLACK_KEY"],
        allow_unsigned: true
      )

    skill = Enum.find(kit.skills, &(&1.name == skill_name))
    build_ctx(skill, supervisor)
  end

  defp update_ctx(supervisor) do
    {:ok, [kit]} = WebhookKit.load_kits([])
    skill = Enum.find(kit.skills, &(&1.name == "webhook:update"))
    build_ctx(skill, supervisor)
  end

  defp build_ctx(skill, supervisor) do
    skill.metadata
    |> Map.put(:supervisor, supervisor)
    |> Map.put(:agent_name, "kit-agent")
    |> Map.put(:agent, %SkAgent{name: "kit-agent", description: "", system_prompt: ""})
  end

  defp fetch_webhooks(sup) do
    {:ok, list} = Webhook.list(%{agent_name: "kit-agent"}, supervisor: sup)
    list
  end
end
