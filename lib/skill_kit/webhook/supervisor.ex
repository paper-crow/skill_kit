defmodule SkillKit.Webhook.Supervisor do
  @moduledoc """
  Supervision tree for the webhook adapter.

  Starts `SkillKit.Webhook.Registry`, the configured `Store` backend
  (default `SkillKit.Webhook.Store.Memory`), `SkillKit.Webhook.Idempotency`,
  and the configured `Inbox` backend (default
  `SkillKit.Webhook.Inbox.Memory`).

  Named by default as `SkillKit.Webhook` so the facade can default its
  supervisor reference to the module name.
  """

  use Supervisor

  alias SkillKit.Webhook.Idempotency
  alias SkillKit.Webhook.Inbox
  alias SkillKit.Webhook.Registry, as: WebhookRegistry
  alias SkillKit.Webhook.Store

  @type opt ::
          {:name, atom()}
          | {:store, {module(), keyword()}}
          | {:inbox, {module(), keyword()}}

  @default_store {Store.Memory, []}
  @default_inbox {Inbox.Memory, []}

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
    {inbox_mod, inbox_cfg} = Keyword.get(opts, :inbox, @default_inbox)

    :persistent_term.put({__MODULE__, :store, name}, {store_mod, store_name(name)})
    :persistent_term.put({__MODULE__, :inbox, name}, {inbox_mod, inbox_name(name)})

    children = [
      {WebhookRegistry, name: registry_name(name)},
      {store_mod, [name: store_name(name)] ++ store_cfg},
      {Idempotency, name: idempotency_name(name)},
      {inbox_mod, [name: inbox_name(name)] ++ inbox_cfg}
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

  @doc "Derives the Inbox process name for a given supervisor name."
  @spec inbox_name(atom()) :: atom()
  def inbox_name(supervisor), do: Module.concat(supervisor, Inbox)

  @doc """
  Returns the `{inbox_module, inbox_name}` tuple for the configured inbox,
  as recorded during supervisor init. Used by the Plug to call
  `Inbox.put/2` without knowing the impl module ahead of time.
  """
  @spec inbox_ref(atom()) :: {module(), atom()}
  def inbox_ref(supervisor) do
    :persistent_term.get({__MODULE__, :inbox, supervisor})
  end

  @doc """
  Returns the `{store_module, store_name}` tuple for the configured store,
  as recorded during supervisor init. The Webhook facade reads this so
  every `register`/`get`/`list`/`unregister` call lands on the configured
  store, not the default `Store.Memory`.
  """
  @spec store_ref(atom()) :: {module(), atom()}
  def store_ref(supervisor) do
    :persistent_term.get({__MODULE__, :store, supervisor})
  end
end
