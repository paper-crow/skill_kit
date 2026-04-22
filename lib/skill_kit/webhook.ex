defmodule SkillKit.Webhook do
  @moduledoc """
  Primary struct and public facade for the webhook adapter.

  A `%SkillKit.Webhook{}` represents a registered HTTP endpoint bound to an
  agent. Inbound requests matching the webhook's id are verified, then
  cast as user messages to the agent's mailbox.

  The module also acts as a supervisor facade via `child_spec/1`, so
  hosts drop `{SkillKit.Webhook, []}` into their application tree. Public
  API (`register/2`, `get/2`, etc.) is added in later tasks.
  """

  @type verifier_binding :: {module(), map()}
  @type idempotency_config :: map() | nil

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

  defdelegate child_spec(opts), to: SkillKit.Webhook.Supervisor
end
