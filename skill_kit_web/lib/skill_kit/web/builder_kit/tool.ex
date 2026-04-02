defmodule SkillKit.Web.BuilderKit.Tool do
  @moduledoc """
  Tool implementation for build pipeline operations.

  Dispatches to the appropriate handler based on the activated skill name.
  All operations use the docs_root from the execution context.
  """

  @behaviour SkillKit.Tool

  alias SkillKit.Web.BuilderKit.Graph

  @impl true
  def definition do
    %SkillKit.Tool{
      name: "build",
      description:
        "Build pipeline — manage document-to-code graph, generate requirements and plans",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" => "Document path relative to docs root"
          },
          "code_files" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Code file paths relative to project root"
          },
          "content" => %{"type" => "string", "description" => "Document or file content"}
        }
      }
    }
  end

  @impl true
  def execute(%SkillKit.ToolExecution{skill: skill, input: input, context: context}) do
    docs_root = Map.get(context, :docs_root, SkillKitWeb.docs_root())
    dispatch(skill.name, input, docs_root, context)
  end

  @impl true
  def resume(_execution, _state, _decision) do
    {:error, :not_resumable}
  end

  # -- Dispatch ----------------------------------------------------------------

  defp dispatch("build:graph_read", _input, docs_root, _context) do
    case Graph.read(docs_root) do
      {:ok, graph} -> {:ok, Jason.encode!(graph, pretty: true)}
      {:error, reason} -> {:error, "Failed to read graph: #{inspect(reason)}"}
    end
  end

  defp dispatch("build:graph_link", input, docs_root, _context) do
    doc_path = input["document"]
    code_files = input["code_files"] || []

    with {:ok, graph} <- Graph.read(docs_root) do
      existing = Graph.find_mapping(graph, doc_path)

      mapping =
        if existing do
          merged_files = Enum.uniq(Map.get(existing, "code_files", []) ++ code_files)
          Map.put(existing, "code_files", merged_files)
        else
          Graph.build_mapping(doc_path, code_files: code_files)
        end

      updated = Graph.put_mapping(graph, mapping)

      case Graph.write(docs_root, updated) do
        :ok -> {:ok, "Linked #{doc_path} to #{inspect(code_files)}"}
        {:error, reason} -> {:error, "Failed to write graph: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch("build:graph_unlink", input, docs_root, _context) do
    doc_path = input["document"]

    with {:ok, graph} <- Graph.read(docs_root) do
      updated = Graph.remove_mapping(graph, doc_path)

      case Graph.write(docs_root, updated) do
        :ok -> {:ok, "Unlinked #{doc_path}"}
        {:error, reason} -> {:error, "Failed to write graph: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch("build:graph_update", input, docs_root, _context) do
    doc_path = input["document"]

    with {:ok, graph} <- Graph.read(docs_root) do
      existing = Graph.find_mapping(graph, doc_path) || Graph.build_mapping(doc_path)

      mapping =
        existing
        |> maybe_put(input, "code_files")
        |> maybe_put(input, "last_hash")
        |> maybe_put(input, "requirements")
        |> maybe_put(input, "plan")

      updated = Graph.put_mapping(graph, mapping)

      case Graph.write(docs_root, updated) do
        :ok -> {:ok, "Updated graph for #{doc_path}"}
        {:error, reason} -> {:error, "Failed to write graph: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch("build:requirements", input, docs_root, _context) do
    doc_path = input["document"]
    build_root = Path.join(docs_root, ".build/requirements")

    with :ok <- File.mkdir_p(build_root) do
      out_path = Path.join(".build/requirements", derive_filename(doc_path))
      abs_out = Path.join(docs_root, out_path)

      content = input["content"] || read_document(docs_root, doc_path)
      placeholder = build_requirements_placeholder(doc_path, content)

      case File.write(abs_out, placeholder) do
        :ok ->
          update_graph_artifact(docs_root, doc_path, "requirements", out_path)

          {:ok,
           "Requirements document written to #{out_path}. Please review and edit it, then tell me to proceed."}

        {:error, reason} ->
          {:error, "Failed to write requirements: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch("build:plan", input, docs_root, _context) do
    doc_path = input["document"]
    build_root = Path.join(docs_root, ".build/plans")

    with :ok <- File.mkdir_p(build_root) do
      out_path = Path.join(".build/plans", derive_filename(doc_path))
      abs_out = Path.join(docs_root, out_path)

      placeholder = build_plan_placeholder(docs_root, doc_path)

      case File.write(abs_out, placeholder) do
        :ok ->
          update_graph_artifact(docs_root, doc_path, "plan", out_path)

          {:ok,
           "Implementation plan written to #{out_path}. Please review and edit it, then tell me to proceed."}

        {:error, reason} ->
          {:error, "Failed to write plan: #{inspect(reason)}"}
      end
    end
  end

  defp dispatch("build:write_code", input, _docs_root, context) do
    project_root = Map.get(context, :project_root, SkillKitWeb.project_root())

    case validate_project_path(project_root, input["path"]) do
      {:ok, abs_path} ->
        if input["content"] do
          with :ok <- File.mkdir_p(Path.dirname(abs_path)),
               :ok <- File.write(abs_path, input["content"]) do
            {:ok, "Wrote #{input["path"]}"}
          end
        else
          case File.read(abs_path) do
            {:ok, content} -> {:ok, content}
            {:error, :enoent} -> {:error, "File not found: #{input["path"]}"}
            {:error, reason} -> {:error, "Read failed: #{inspect(reason)}"}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("build:generate", input, docs_root, _context) do
    doc_path = input["document"]

    with {:ok, graph} <- Graph.read(docs_root) do
      case Graph.find_mapping(graph, doc_path) do
        nil ->
          {:error, "No build graph mapping for #{doc_path}. Use build:graph_link first."}

        mapping ->
          plan_path = mapping["plan"]

          if plan_path do
            {:ok,
             "Ready to execute plan at #{plan_path}. Use build:write_code to create or update each file, then build:graph_update to record the new hash."}
          else
            {:error, "No plan found for #{doc_path}. Run build:plan first."}
          end
      end
    end
  end

  defp dispatch(skill_name, _input, _docs_root, _context) do
    {:error, "Unknown skill: #{skill_name}"}
  end

  # -- Helpers -----------------------------------------------------------------

  defp maybe_put(mapping, input, key) do
    case Map.get(input, key) do
      nil -> mapping
      value -> Map.put(mapping, key, value)
    end
  end

  defp derive_filename(doc_path) do
    doc_path
    |> Path.rootname()
    |> String.replace("/", "_")
    |> Kernel.<>(".md")
  end

  defp read_document(docs_root, doc_path) do
    case File.read(Path.join(docs_root, doc_path)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp build_requirements_placeholder(doc_path, content) do
    summary =
      content
      |> String.split("\n")
      |> Enum.take(5)
      |> Enum.join("\n")

    """
    # Requirements: #{doc_path}

    ## Source document

    #{summary}

    ## Functional requirements

    <!-- Extract requirements from the document above. Number each one. -->

    1. TODO

    ## Affected code files

    <!-- List code files that need to change. -->

    ## Acceptance criteria

    <!-- Define how to verify each requirement is met. -->
    """
  end

  defp build_plan_placeholder(docs_root, doc_path) do
    with {:ok, graph} <- Graph.read(docs_root),
         mapping when not is_nil(mapping) <- Graph.find_mapping(graph, doc_path),
         req_path when not is_nil(req_path) <- mapping["requirements"] do
      """
      # Implementation plan: #{doc_path}

      ## Requirements

      See: #{req_path}

      ## Steps

      <!-- Step-by-step implementation. For each step, list the file and changes needed. -->

      ### Step 1

      **File:** TODO
      **Changes:** TODO

      ## Testing

      <!-- How to verify the implementation matches the requirements. -->
      """
    else
      _ ->
        """
        # Implementation plan: #{doc_path}

        ## Steps

        <!-- No requirements document found. Create one with build:requirements first. -->
        """
    end
  end

  defp update_graph_artifact(docs_root, doc_path, artifact_key, artifact_path) do
    case Graph.read(docs_root) do
      {:ok, graph} ->
        existing = Graph.find_mapping(graph, doc_path) || Graph.build_mapping(doc_path)
        updated_mapping = Map.put(existing, artifact_key, artifact_path)
        updated_graph = Graph.put_mapping(graph, updated_mapping)
        Graph.write(docs_root, updated_graph)

      _ ->
        :ok
    end
  end

  defp validate_project_path(root, path) when is_binary(path) do
    expanded_root = Path.expand(root)
    abs_path = Path.expand(Path.join(root, path))

    if String.starts_with?(abs_path, expanded_root <> "/") do
      {:ok, abs_path}
    else
      {:error, "Path traversal not allowed: #{path}"}
    end
  end

  defp validate_project_path(_root, _path) do
    {:error, "Path is required"}
  end
end
