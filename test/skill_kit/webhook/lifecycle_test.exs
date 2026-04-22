defmodule SkillKit.Webhook.LifecycleTest do
  use ExUnit.Case, async: false

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Lifecycle
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookSupervisor.start_link(name: name)
    {:ok, supervisor: name}
  end

  test "execute/2 attaches the agent to the registry", %{supervisor: sup} do
    reg_atom = :"reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(keys: :unique, name: reg_atom)

    agent = %SkAgent{
      name: "lc-agent",
      description: "",
      system_prompt: "",
      registry: reg_atom
    }

    assert :ok = Lifecycle.execute(%{supervisor: sup}, %{definition: agent})

    assert {:ok, ^agent} =
             WebhookRegistry.whereis("lc-agent", registry: WebhookSupervisor.registry_name(sup))
  end

  test "execute/2 is a no-op when the context lacks a definition", %{supervisor: sup} do
    assert :ok = Lifecycle.execute(%{supervisor: sup}, %{})
  end
end
