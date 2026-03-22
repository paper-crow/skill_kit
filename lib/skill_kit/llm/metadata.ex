defmodule SkillKit.LLM.Metadata do
  @moduledoc """
  Extracts LLM backend configuration from skill metadata.

  Skills declare LLM preferences via spec-compliant flat metadata keys
  prefixed with `skill_kit:backend:*`:

      metadata:
        skill_kit:backend:provider: anthropic
        skill_kit:backend:model: claude-sonnet-4-20250514
        skill_kit:backend:max-tokens: "4096"

  This module parses those keys into a `{module, config}` tuple
  suitable for `SkillKit.LLM.stream/2`.
  """

  @prefix "skill_kit:backend:"

  @providers %{
    "anthropic" => SkillKit.LLM.Anthropic
  }

  # Explicit allowlist mapping metadata key strings to atom keys + coercion type.
  # Using an allowlist avoids String.to_atom on untrusted input.
  @known_keys %{
    "model" => {:model, :string},
    "max-tokens" => {:max_tokens, :integer},
    "temperature" => {:temperature, :float},
    "top-p" => {:top_p, :float}
  }

  @doc """
  Extracts backend configuration from a skill's metadata map.

  Returns:
  - `{:ok, {module, opts}}` — when a valid provider is found
  - `:default` — when no `skill_kit:backend:*` keys are present
  - `{:error, {:unknown_provider, name}}` — when provider is not recognized
  """
  @spec extract_backend(map() | nil) :: {:ok, {module(), keyword()}} | :default | {:error, term()}
  def extract_backend(nil), do: :default

  def extract_backend(metadata) when is_map(metadata) do
    backend_keys =
      metadata
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, @prefix) end)
      |> Enum.map(fn {k, v} -> {String.replace_prefix(k, @prefix, ""), v} end)
      |> Map.new()

    case Map.pop(backend_keys, "provider") do
      {nil, _} ->
        :default

      {provider_name, rest} ->
        case Map.fetch(@providers, provider_name) do
          {:ok, mod} ->
            opts = coerce_opts(rest)
            {:ok, {mod, opts}}

          :error ->
            {:error, {:unknown_provider, provider_name}}
        end
    end
  end

  defp coerce_opts(map) do
    Enum.flat_map(map, fn {k, v} ->
      case Map.fetch(@known_keys, k) do
        {:ok, {atom_key, type}} -> [{atom_key, coerce_value(type, v)}]
        :error -> []
      end
    end)
  end

  defp coerce_value(:integer, value), do: String.to_integer(value)
  defp coerce_value(:float, value), do: String.to_float(value)
  defp coerce_value(:string, value), do: value
end
