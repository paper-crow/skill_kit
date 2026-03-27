defmodule SkillKit.Hook do
  @moduledoc """
  Represents a lifecycle hook that fires at agent boundaries.

  Hooks are gate-only: they can allow, deny, or suspend execution —
  never transform input or output.

  ## Fields

  | Field      | Type                  | Description                                          |
  |------------|-----------------------|------------------------------------------------------|
  | `:event`   | `event()`             | Which lifecycle event triggers this hook             |
  | `:matcher` | `Regex.t()`           | Regex matched against the boundary's match target    |
  | `:handler` | `handler()`           | Logic to run — function, MFA, or `{module, config}`  |
  """

  @type event ::
          :pre_tool_use
          | :post_tool_use
          | :pre_subagent
          | :post_subagent
          | :pre_skill_activation
          | :post_skill_activation
          | :pre_conversation_save
          | :post_conversation_save
          | :pre_conversation_load
          | :post_conversation_load
          | :pre_llm_request
          | :post_llm_request
          | :pre_turn
          | :post_turn
          | :pre_agent
          | :post_agent

  @type handler :: {module(), map()} | (map() -> any()) | {module(), atom(), list()}

  @type t :: %__MODULE__{
          event: event() | nil,
          matcher: Regex.t() | nil,
          handler: handler() | nil
        }

  defstruct [:event, :matcher, :handler]
end
