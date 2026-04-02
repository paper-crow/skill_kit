defmodule SkillKit.Web.BuilderKit.ChangeDetector do
  @moduledoc """
  Detects meaningful document changes by comparing content hashes
  against the build graph.

  Called from EditorLive after document saves. Returns a change
  description when the document has a graph mapping and its content
  hash differs from the last recorded build, or `:no_change` otherwise.

  This module is pure functions — no GenServer, no side effects beyond
  reading the graph file from disk.
  """

  alias SkillKit.Web.BuilderKit.Graph

  @type change :: %{
          document: String.t(),
          new_hash: String.t(),
          code_files: [String.t()],
          requirements: String.t() | nil,
          plan: String.t() | nil
        }

  @doc """
  Checks whether a document has meaningfully changed since its last build.

  Returns `{:changed, change_info}` if the document is tracked in the
  graph and its content hash differs, or `:no_change` otherwise.
  Untracked documents return `:no_change` — the agent must first link
  them via `build:graph_link`.
  """
  @spec check(String.t(), String.t(), String.t()) :: {:changed, change()} | :no_change
  def check(docs_root, doc_path, content) do
    case Graph.read(docs_root) do
      {:ok, graph} -> check_graph(graph, doc_path, content)
      {:error, _} -> :no_change
    end
  end

  defp check_graph(graph, doc_path, content) do
    case Graph.find_mapping(graph, doc_path) do
      nil ->
        :no_change

      mapping ->
        new_hash = Graph.content_hash(content)

        if mapping["last_hash"] == new_hash do
          :no_change
        else
          {:changed,
           %{
             document: doc_path,
             new_hash: new_hash,
             code_files: Map.get(mapping, "code_files", []),
             requirements: mapping["requirements"],
             plan: mapping["plan"]
           }}
        end
    end
  end

  @doc """
  Formats a change detection result into a message for the agent.
  """
  @spec format_agent_message(change()) :: String.t()
  def format_agent_message(change) do
    files_note =
      case change.code_files do
        [] -> "No code files are linked yet."
        files -> "Linked code files: #{Enum.join(files, ", ")}"
      end

    """
    Document "#{change.document}" has changed since the last build. \
    #{files_note} \
    Please run build:requirements to generate an updated requirements document, \
    then wait for the user to review it before proceeding.\
    """
  end
end
