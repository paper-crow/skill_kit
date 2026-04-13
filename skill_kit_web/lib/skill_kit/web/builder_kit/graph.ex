defmodule SkillKit.Web.BuilderKit.Graph do
  @moduledoc """
  Pure functions for managing the document-to-code build graph.

  The graph is a JSON file (`build_graph.json`) in the docs root that
  maps document paths to their related code files, content hashes,
  and generated intermediary documents (requirements, plans).

  ## Graph structure

      %{
        "version" => 1,
        "mappings" => [
          %{
            "document" => "features/auth.md",
            "code_files" => ["lib/my_app/auth.ex"],
            "last_hash" => "sha256hex...",
            "requirements" => ".build/requirements/auth.md",
            "plan" => ".build/plans/auth.md"
          }
        ]
      }
  """

  @graph_filename "build_graph.json"
  @current_version 1

  @doc """
  Reads the build graph from disk. Returns an empty graph if the file
  does not exist or contains invalid JSON.
  """
  def read(docs_root) do
    path = graph_path(docs_root)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, graph} -> {:ok, graph}
          {:error, _} -> {:ok, empty_graph()}
        end

      {:error, :enoent} ->
        {:ok, empty_graph()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes the build graph to disk.
  """
  def write(docs_root, graph) do
    path = graph_path(docs_root)

    case Jason.encode(graph, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds the mapping for a given document path, or nil if not mapped.
  """
  def find_mapping(graph, doc_path) do
    graph
    |> Map.get("mappings", [])
    |> Enum.find(&(&1["document"] == doc_path))
  end

  @doc """
  Adds or updates a mapping in the graph. Matches on document path.
  """
  def put_mapping(graph, mapping) do
    mappings = Map.get(graph, "mappings", [])
    doc_path = mapping["document"]
    updated = Enum.reject(mappings, &(&1["document"] == doc_path))
    Map.put(graph, "mappings", updated ++ [mapping])
  end

  @doc """
  Removes the mapping for a given document path.
  """
  def remove_mapping(graph, doc_path) do
    mappings = Map.get(graph, "mappings", [])
    updated = Enum.reject(mappings, &(&1["document"] == doc_path))
    Map.put(graph, "mappings", updated)
  end

  @doc """
  Returns true if the document content has changed since the last recorded hash.
  Returns true if the document has no mapping (never built).
  """
  def changed?(graph, doc_path, content) do
    case find_mapping(graph, doc_path) do
      nil -> true
      mapping -> mapping["last_hash"] != content_hash(content)
    end
  end

  @doc """
  Computes a SHA-256 hex digest of the given content.
  """
  def content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Returns an empty graph with the current version.
  """
  def empty_graph do
    %{"version" => @current_version, "mappings" => []}
  end

  @doc """
  Builds a new mapping struct for a document.
  """
  def build_mapping(doc_path, opts \\ []) do
    %{
      "document" => doc_path,
      "code_files" => Keyword.get(opts, :code_files, []),
      "last_hash" => Keyword.get(opts, :last_hash, nil),
      "requirements" => Keyword.get(opts, :requirements, nil),
      "plan" => Keyword.get(opts, :plan, nil)
    }
  end

  defp graph_path(docs_root) do
    Path.join(docs_root, @graph_filename)
  end
end
