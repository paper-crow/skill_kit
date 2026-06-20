defmodule SkillKit.AgentRef do
  @moduledoc """
  Opaque reference to a running agent.

  Returned by `SkillKit.start_agent/2`. Used with `SkillKit.send_message/2`
  and `SkillKit.stop_agent/1`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          registry: atom(),
          supervisor_pid: pid() | nil
        }

  @type origin :: :root | :skill | :delivery | :subloop | :other

  @enforce_keys [:name, :registry, :supervisor_pid]
  defstruct [:name, :registry, :supervisor_pid]

  @doc "Builds an `AgentRef` from an `%Agent{}` struct (registry already set)."
  @spec from_agent(SkillKit.Agent.t()) :: t()
  def from_agent(%SkillKit.Agent{name: name, registry: registry}) do
    %__MODULE__{name: name, registry: registry, supervisor_pid: nil}
  end

  @doc """
  Classifies an agent name relative to a `root` agent name.

  Sub-loops are named `"<root>/<kind>:<id>"` (e.g. `"neve/skill:plan"`,
  `"neve/delivery:abc"`), so the prefix reveals where the name came
  from:

    * `:root` — the top-level conversation
    * `:skill` — an `activate_skill` sub-loop
    * `:delivery` — a webhook delivery sub-loop
    * `:subloop` — any other descendant sub-loop
    * `:other` — an unrelated agent
  """
  @spec origin(String.t(), String.t()) :: origin()
  def origin(name, root) do
    size = byte_size(root)

    case name do
      ^root -> :root
      <<^root::binary-size(size), "/skill:", _::binary>> -> :skill
      <<^root::binary-size(size), "/delivery:", _::binary>> -> :delivery
      <<^root::binary-size(size), "/", _::binary>> -> :subloop
      _ -> :other
    end
  end
end
