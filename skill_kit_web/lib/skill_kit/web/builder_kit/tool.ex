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
      description: "Build pipeline — manage document-to-code graph, generate requirements and plans",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "document" => %{"type" => "string", "description" => "Document path relative to docs root"},
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

  defp dispatch(skill_name, _input, _docs_root, _context) do
    {:error, "Unknown skill: #{skill_name}"}
  end

  defp maybe_put(mapping, input, key) do
    case Map.get(input, key) do
      nil -> mapping
      value -> Map.put(mapping, key, value)
    end
  end
end
