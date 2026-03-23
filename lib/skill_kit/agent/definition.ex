defmodule SkillKit.Agent.Definition do
  @moduledoc """
  Data struct and parser for AGENT.md files.

  An agent definition carries all the configuration needed to start
  an agent: identity, system prompt, tool restrictions, LLM model,
  workspace path, and mailbox tuning.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          capabilities: [String.t()],
          model: String.t() | nil,
          system_prompt: String.t(),
          path: String.t(),
          workspace: String.t(),
          max_agent_depth: non_neg_integer(),
          mailbox: %{max_messages: pos_integer(), flush_interval: pos_integer()}
        }

  @enforce_keys [:name, :description, :system_prompt, :path, :workspace]
  defstruct [
    :name,
    :description,
    :model,
    :system_prompt,
    :path,
    :workspace,
    capabilities: [],
    max_agent_depth: 1,
    mailbox: %{max_messages: 10, flush_interval: 500}
  ]

  @doc """
  Parses an AGENT.md file at `path` into a `%Definition{}`.

  Returns `{:ok, definition}` or `{:error, reason}`.
  """
  @spec parse(Path.t()) :: {:ok, t()} | {:error, term()}
  def parse(path) do
    with {:ok, yaml, body} <- SkillKit.Frontmatter.parse_file(path) do
      build(yaml, body, path)
    end
  end

  defp build(yaml, body, path) do
    metadata = Map.get(yaml, "metadata", %{})

    with {:ok, name} <- fetch_required(yaml, "name"),
         {:ok, description} <- fetch_required(yaml, "description") do
      workspace =
        case Map.get(metadata, "workspace") do
          nil -> Path.dirname(path)
          explicit -> Path.expand(explicit)
        end

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         capabilities: parse_list(Map.get(yaml, "capabilities")),
         model: Map.get(yaml, "model"),
         system_prompt: body,
         path: path,
         workspace: workspace,
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

  defp parse_list(nil), do: []
  defp parse_list(items) when is_binary(items), do: String.split(items, ~r/[\s,]+/, trim: true)
  defp parse_list(items) when is_list(items), do: items

  defp parse_int(metadata, key, default) do
    case Map.get(metadata, key) do
      nil -> default
      val when is_binary(val) -> String.to_integer(val)
      val when is_integer(val) -> val
    end
  end
end
