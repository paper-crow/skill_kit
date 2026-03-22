defmodule SkillKit.Frontmatter do
  @moduledoc """
  Shared frontmatter parsing for SKILL.md and AGENT.md files.

  Splits a markdown file with YAML frontmatter into its parts
  and parses the YAML. Used by both the skill parser and the
  agent definition parser.

  YAML is always parsed with `atoms: false` to prevent atom table
  exhaustion from untrusted files.
  """

  @doc """
  Reads a file and parses its frontmatter.

  Returns `{:ok, yaml_map, body}` or `{:error, reason}`.
  """
  @spec parse_file(Path.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path) do
      parse(content)
    end
  end

  @doc """
  Parses a string containing YAML frontmatter and a markdown body.

  Returns `{:ok, yaml_map, body}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse(content) do
    with {:ok, frontmatter, body} <- split(content),
         {:ok, yaml_map} <- parse_yaml(frontmatter) do
      {:ok, yaml_map, body}
    end
  end

  @doc """
  Splits content into frontmatter string and body string.

  Returns `{:ok, frontmatter, body}` or `{:error, :invalid_frontmatter}`.
  """
  @spec split(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_frontmatter}
  def split("---\n" <> rest), do: do_split(rest)
  def split(content), do: do_split(content)

  defp do_split(content) do
    case String.split(content, ~r/\n---(\n|$)/, parts: 2) do
      [frontmatter, body] -> {:ok, frontmatter, String.trim(body)}
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp parse_yaml(yaml_str) do
    YamlElixir.read_from_string(yaml_str, atoms: false)
  end
end
