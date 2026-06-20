defmodule Mix.SkillKit.Dotenv do
  @moduledoc false
  # Internal dev-tooling helper shared by the SkillKit mix tasks.
  #
  # Loads KEY=value pairs from a project-root `.env` into the process
  # environment. Lines starting with `#` are ignored. Existing env vars
  # take precedence (so a shell export can override the file). This is a
  # convenience for running tasks locally, not a public configuration
  # surface — apps should manage their own environment.

  @doc "Loads `.env` (or `path`) into the process environment."
  def load(path \\ ".env") do
    case File.read(path) do
      {:ok, content} -> apply_env(content)
      {:error, _} -> :ok
    end
  end

  defp apply_env(content) do
    content
    |> String.split("\n")
    |> Enum.each(&put_line/1)
  end

  defp put_line(line), do: put_kv(String.trim(line))

  defp put_kv(""), do: :ok
  defp put_kv("#" <> _), do: :ok

  defp put_kv(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> put_if_missing(String.trim(key), unquote_value(value))
      _ -> :ok
    end
  end

  defp put_if_missing(key, value) do
    case System.get_env(key) do
      nil -> System.put_env(key, value)
      _existing -> :ok
    end
  end

  defp unquote_value(value), do: strip_quotes(String.trim(value))

  defp strip_quotes(<<?", rest::binary>>), do: String.trim_trailing(rest, ~s("))
  defp strip_quotes(<<?', rest::binary>>), do: String.trim_trailing(rest, "'")
  defp strip_quotes(value), do: value
end
