defmodule SkillKit.Agent do
  @moduledoc """
  Data struct and parser for AGENT.md files.

  An agent carries all the configuration needed to start an agent process:
  identity, system prompt, skills, runtime, scope, and mailbox tuning.

  The struct serves as the single source of truth flowing through the
  entire supervision tree.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          model: String.t() | nil,
          system_prompt: String.t(),
          max_agent_depth: non_neg_integer(),
          mailbox: %{max_messages: pos_integer(), flush_interval: pos_integer()},
          tools: [{module(), keyword()}],
          skills: [{module(), keyword()}],
          runtime: {module(), keyword()},
          scope: term(),
          conversation_store: {module(), keyword()} | nil,
          caller: pid() | nil,
          parent_ref: SkillKit.AgentRef.t() | nil,
          registry: atom() | nil,
          depth: non_neg_integer(),
          initial_messages: [term()]
        }

  @enforce_keys [:name, :description, :system_prompt]
  defstruct [
    :name,
    :description,
    :model,
    :system_prompt,
    :scope,
    :conversation_store,
    :caller,
    :parent_ref,
    :registry,
    initial_messages: [],
    max_agent_depth: 1,
    mailbox: %{max_messages: 10, flush_interval: 500},
    tools: [],
    skills: [],
    runtime: {SkillKit.Runtime.Local, []},
    depth: 0
  ]

  @doc """
  Parses AGENT.md content into a `%SkillKit.Agent{}`.

  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) do
    with {:ok, yaml, body} <- SkillKit.Frontmatter.parse(content) do
      build(yaml, body)
    end
  end

  defp build(yaml, body) do
    metadata = Map.get(yaml, "metadata", %{})

    with {:ok, name} <- fetch_required(yaml, "name"),
         {:ok, description} <- fetch_required(yaml, "description") do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         model: Map.get(yaml, "model"),
         system_prompt: body,
         max_agent_depth: parse_int(metadata, "max_agent_depth", 1),
         mailbox: %{
           max_messages: parse_int(metadata, "mailbox_max_messages", 10),
           flush_interval: parse_int(metadata, "mailbox_flush_interval", 500)
         }
       }}
    end
  end

  defp fetch_required(yaml, key) do
    case Map.fetch(yaml, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp parse_int(metadata, key, default) do
    case Map.get(metadata, key) do
      nil -> default
      val when is_binary(val) -> String.to_integer(val)
      val when is_integer(val) -> val
    end
  end
end
