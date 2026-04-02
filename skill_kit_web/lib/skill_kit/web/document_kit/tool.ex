defmodule SkillKit.Web.DocumentKit.Tool do
  @moduledoc """
  Tool implementation for document operations.

  Dispatches to the appropriate handler based on the activated skill name.
  All file operations are constrained to the project root via path validation.
  """

  @behaviour SkillKit.Tool

  @impl true
  def definition do
    %SkillKit.Tool{
      name: "docs",
      description: "Document operations — create, read, update, list, search, structure, history",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative file path"},
          "content" => %{"type" => "string", "description" => "File content"},
          "query" => %{"type" => "string", "description" => "Search query"},
          "limit" => %{"type" => "integer", "description" => "Result limit"}
        }
      }
    }
  end

  @impl true
  def execute(%SkillKit.ToolExecution{skill: skill, input: input, context: context}) do
    dispatch(skill.name, input, context)
  end

  @impl true
  def resume(_execution, _state, _decision) do
    {:error, :not_resumable}
  end

  # -- Dispatch ----------------------------------------------------------------

  defp dispatch("docs:ask", input, context) do
    caller = get_in(context, [:scope, Access.key(:caller)])

    if caller do
      question = %{
        question: input["question"],
        subtext: input["subtext"]
      }

      send(caller, {:onboarding_question, question})
      {:ok, "Question sent to user. Wait for their response."}
    else
      {:error, "No caller process available"}
    end
  end

  # All remaining skills operate on the docs_root filesystem
  defp dispatch(skill_name, input, context) do
    root = docs_root(context)
    dispatch_docs(skill_name, input, root)
  end

  defp dispatch_docs("docs:create", input, root) do
    with {:ok, abs_path} <- validate_path(root, input["path"]),
         :ok <- ensure_not_exists(abs_path),
         :ok <- File.mkdir_p(Path.dirname(abs_path)),
         :ok <- File.write(abs_path, input["content"]) do
      {:ok, "Created #{input["path"]}"}
    end
  end

  defp dispatch_docs("docs:read", input, root) do
    with {:ok, abs_path} <- validate_path(root, input["path"]),
         {:ok, content} <- File.read(abs_path) do
      {:ok, content}
    else
      {:error, :enoent} -> {:error, "File not found: #{input["path"]}"}
      error -> error
    end
  end

  defp dispatch_docs("docs:update", input, root) do
    with {:ok, abs_path} <- validate_path(root, input["path"]),
         :ok <- ensure_exists(abs_path),
         :ok <- File.write(abs_path, input["content"]) do
      {:ok, "Updated #{input["path"]}"}
    end
  end

  defp dispatch_docs("docs:list", _input, root) do
    files =
      root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    {:ok, files}
  end

  defp dispatch_docs("docs:search", input, root) do
    query = input["query"]

    results =
      root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(&search_file(&1, query, root))

    {:ok, results}
  end

  defp dispatch_docs("docs:structure", input, root) do
    with {:ok, abs_path} <- validate_path(root, input["path"]),
         {:ok, content} <- File.read(abs_path) do
      headings = parse_headings(content)
      {:ok, headings}
    else
      {:error, :enoent} -> {:error, "File not found: #{input["path"]}"}
      error -> error
    end
  end

  defp dispatch_docs("docs:history", input, root) do
    limit = Map.get(input, "limit", 20)

    case validate_path(root, input["path"]) do
      {:ok, abs_path} -> run_git_log(abs_path, limit, root)
      error -> error
    end
  end

  defp dispatch_docs(skill_name, _input, _root) do
    {:error, "Unknown skill: #{skill_name}"}
  end

  defp docs_root(context) do
    get_in(context, [:scope, Access.key(:docs_root)]) ||
      Map.get(context, :docs_root) ||
      SkillKitWeb.docs_root()
  end

  defp run_git_log(abs_path, limit, root) do
    limit_str = Integer.to_string(limit)

    case System.cmd("git", ["log", "--oneline", "-n", limit_str, "--", abs_path],
           cd: root,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _} -> {:error, "git log failed: #{String.trim(output)}"}
    end
  end

  # -- Path Validation ---------------------------------------------------------

  defp validate_path(root, path) when is_binary(path) do
    expanded_root = Path.expand(root)
    abs_path = Path.expand(Path.join(root, path))

    if String.starts_with?(abs_path, expanded_root <> "/") do
      {:ok, abs_path}
    else
      {:error, "Path traversal not allowed: #{path}"}
    end
  end

  defp validate_path(_root, _path) do
    {:error, "Path is required"}
  end

  # -- Helpers -----------------------------------------------------------------

  defp ensure_not_exists(path) do
    if File.exists?(path) do
      {:error, "File already exists: #{path}"}
    else
      :ok
    end
  end

  defp ensure_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "File not found: #{path}"}
    end
  end

  defp search_file(abs_path, query, root) do
    case File.read(abs_path) do
      {:ok, content} ->
        matching_lines =
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _num} -> String.contains?(line, query) end)

        case matching_lines do
          [] ->
            []

          lines ->
            rel_path = Path.relative_to(abs_path, root)

            [
              %{
                path: rel_path,
                matches: Enum.map(lines, fn {line, num} -> %{line: num, text: line} end)
              }
            ]
        end

      {:error, _} ->
        []
    end
  end

  defp parse_headings(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#"))
    |> Enum.map(&parse_heading_line/1)
  end

  defp parse_heading_line(line) do
    {hashes, rest} = split_heading(line)
    %{level: String.length(hashes), text: String.trim(rest)}
  end

  defp split_heading(line) do
    [hashes | rest] = String.split(line, " ", parts: 2)
    text = Enum.join(rest, " ")
    {hashes, text}
  end
end
