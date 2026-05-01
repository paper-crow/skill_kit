defmodule SkillKit.Webhook.Lifecycle do
  @moduledoc """
  `:pre_agent` hook handler injected onto every skill in
  `SkillKit.Tools.Webhook`.

  When an agent boots, its Catalog aggregates the hooks from every loaded
  skill. For each skill in the webhook kit, this hook fires once with the
  full `%SkillKit.Agent{}` in its context. The handler calls
  `Webhook.Registry.attach/2` so the Plug can route inbound requests to
  this agent by `name` afterward.
  """

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor

  @doc """
  Hook handler entry point. Called by `SkillKit.Hooks.invoke_handler/2`
  with the handler config and the pre-event context.
  """
  @spec execute(map(), map()) :: :ok
  def execute(%{supervisor: supervisor}, %{definition: %SkAgent{} = agent}) do
    WebhookRegistry.attach(agent, registry: WebhookSupervisor.registry_name(supervisor))
    :ok
  end

  def execute(_config, _context), do: :ok
end
