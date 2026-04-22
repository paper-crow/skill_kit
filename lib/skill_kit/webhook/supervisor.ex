defmodule SkillKit.Webhook.Supervisor do
  @moduledoc """
  Supervision tree for the webhook adapter.

  Starts `SkillKit.Webhook.Registry` and the configured `Store` backend
  (default `SkillKit.Webhook.Store.Memory`) plus `SkillKit.Webhook.Idempotency`.

  Named by default as `SkillKit.Webhook` so the facade can default its
  supervisor reference to the module name.
  """

  use Supervisor

  alias SkillKit.Webhook.Idempotency
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Store

  @type opt :: {:name, atom()} | {:store, {module(), keyword()}}

  @default_store {Store.Memory, []}

  @spec start_link([opt()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, SkillKit.Webhook)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :name, SkillKit.Webhook)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, SkillKit.Webhook)
    {store_mod, store_cfg} = Keyword.get(opts, :store, @default_store)

    children = [
      {WebhookRegistry, name: registry_name(name)},
      {store_mod, [name: store_name(name)] ++ store_cfg},
      {Idempotency, name: idempotency_name(name)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Derives the Registry process name for a given supervisor name."
  @spec registry_name(atom()) :: atom()
  def registry_name(supervisor), do: Module.concat(supervisor, Registry)

  @doc "Derives the Store process name for a given supervisor name."
  @spec store_name(atom()) :: atom()
  def store_name(supervisor), do: Module.concat(supervisor, Store)

  @doc "Derives the Idempotency process name for a given supervisor name."
  @spec idempotency_name(atom()) :: atom()
  def idempotency_name(supervisor), do: Module.concat(supervisor, Idempotency)
end
