defmodule SkillKit.Webhook do
  @moduledoc """
  Primary struct and public facade for the webhook adapter.

  A `%SkillKit.Webhook{}` represents a registered HTTP endpoint bound to an
  agent. Inbound requests matching the webhook's id are verified, then
  cast as user messages to the agent's mailbox.

  The module also acts as a supervisor facade: `{SkillKit.Webhook, opts}`
  in an application tree starts `SkillKit.Webhook.Supervisor` and its
  children (Registry, Store, Idempotency). Public API calls (`register/2`
  etc.) take a `supervisor:` option that defaults to `SkillKit.Webhook`;
  multi-tenant setups override it per tree.
  """

  alias SkillKit.Webhook.Supervisor, as: WebhookSupervisor
  alias SkillKit.Webhook.Url

  @type verifier_binding :: {module(), map()}
  @type idempotency_config :: map() | nil
  @type filter :: map()

  @type t :: %__MODULE__{
          id: String.t(),
          agent_name: String.t(),
          prompt: String.t(),
          verifier: verifier_binding(),
          idempotency: idempotency_config(),
          inserted_at: DateTime.t()
        }

  @enforce_keys [:id, :agent_name, :prompt, :verifier, :inserted_at]
  defstruct [:id, :agent_name, :prompt, :verifier, :idempotency, :inserted_at]

  defdelegate child_spec(opts), to: WebhookSupervisor

  @spec register(t(), keyword()) :: :ok | {:error, term()}
  def register(%__MODULE__{} = webhook, opts \\ []) do
    apply_store(:put, [webhook], opts)
  end

  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, :not_found}
  def get(id, opts \\ []) when is_binary(id) do
    apply_store(:get, [id], opts)
  end

  @spec unregister(String.t(), keyword()) :: :ok
  def unregister(id, opts \\ []) when is_binary(id) do
    apply_store(:delete, [id], opts)
  end

  @spec list(filter(), keyword()) :: {:ok, [t()]}
  def list(filter \\ %{}, opts) when is_map(filter) do
    apply_store(:list, [filter], opts)
  end

  @doc "Builds the externally-visible URL for a webhook."
  @spec url(t(), keyword()) :: String.t()
  defdelegate url(webhook, opts \\ []), to: Url

  # -- Helpers --------------------------------------------------------------

  defp apply_store(fun, extra_args, opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    {module, name} = WebhookSupervisor.store_ref(supervisor)
    apply(module, fun, [[name: name] | extra_args])
  end
end
