defmodule SkillKit.Storage do
  @moduledoc """
  Behaviour and convenience API for pluggable storage backends.

  All file I/O in SkillKit routes through this module, allowing the
  storage layer to be swapped between local filesystem, cloud object
  stores, or in-memory backends for testing.

  ## Configuration

  Set the provider in application config:

      # config/config.exs
      config :skill_kit, SkillKit.Storage,
        provider: SkillKit.Storage.File

      # config/test.exs
      config :skill_kit, SkillKit.Storage,
        provider: SkillKit.Storage.Memory

  ## Using the Convenience API

  Call functions directly on `SkillKit.Storage` — the configured
  provider is resolved automatically:

      Storage.put!("skills/greet/SKILL.md", content)
      {:ok, data} = Storage.read("skills/greet/SKILL.md")
      {:ok, entries} = Storage.list("skills")
      Storage.delete("skills/greet/SKILL.md")

  ## Implementing a Custom Provider

  A provider implements this behaviour's 9 callbacks. For example,
  an S3-backed provider:

      defmodule MyApp.Storage.S3 do
        @behaviour SkillKit.Storage

        @impl true
        def read(path) do
          case ExAws.S3.get_object("my-bucket", path) |> ExAws.request() do
            {:ok, %{body: body}} -> {:ok, body}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def put(path, content) do
          case ExAws.S3.put_object("my-bucket", path, content) |> ExAws.request() do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def list(path) do
          stream =
            ExAws.S3.list_objects("my-bucket", prefix: path <> "/", delimiter: "/")
            |> ExAws.stream!()
            |> Stream.map(& &1.key)
            |> Stream.map(&Path.basename/1)

          {:ok, stream}
        end

        @impl true
        def exists?(path) do
          case ExAws.S3.head_object("my-bucket", path) |> ExAws.request() do
            {:ok, _} -> true
            {:error, _} -> false
          end
        end

        @impl true
        def dir?(path) do
          case list(path) do
            {:ok, entries} -> Enum.any?(entries)
            {:error, _} -> false
          end
        end

        @impl true
        def ensure_dir(_path), do: :ok

        @impl true
        def delete(path) do
          case ExAws.S3.delete_object("my-bucket", path) |> ExAws.request() do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def delete_all(path) do
          {:ok, entries} = list(path)
          deleted = Enum.map(entries, fn key ->
            full = Path.join(path, key)
            delete(full)
            full
          end)
          {:ok, deleted}
        end

        @impl true
        def delete_dir(_path), do: :ok
      end

  Then configure it:

      config :skill_kit, SkillKit.Storage,
        provider: MyApp.Storage.S3

  ## Callback Naming

  Callbacks use storage-agnostic names rather than mirroring Elixir's
  `File` module:

  | Callback | File equivalent | Notes |
  |----------|----------------|-------|
  | `read/1` | `File.read/1` | |
  | `put/2` | `File.write/2` | S3 PUT semantics |
  | `delete/1` | `File.rm/1` | Single file/key |
  | `delete_all/1` | `File.rm_rf/1` | Recursive delete |
  | `list/1` | `File.ls/1` | Returns `Enumerable.t()` for pagination |
  | `exists?/1` | `File.exists?/1` | |
  | `dir?/1` | `File.dir?/1` | S3 checks key prefix |
  | `ensure_dir/1` | `File.mkdir_p/1` | No-op for flat stores |
  | `delete_dir/1` | `File.rmdir/1` | Remove empty directory |

  ## Bang Wrappers

  Three bang functions are provided for operations commonly used in
  contexts where failure should raise:

  - `put!/2` — raises on write failure
  - `ensure_dir!/1` — raises on directory creation failure
  - `delete_all!/1` — raises on failure, returns list of removed paths on success
  """

  @type path :: String.t()

  @callback read(path()) :: {:ok, binary()} | {:error, term()}
  @callback put(path(), iodata()) :: :ok | {:error, term()}
  @callback delete(path()) :: :ok | {:error, term()}
  @callback delete_all(path()) :: {:ok, [String.t()]} | {:error, term()}
  @callback list(path()) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback exists?(path()) :: boolean()
  @callback dir?(path()) :: boolean()
  @callback ensure_dir(path()) :: :ok | {:error, term()}
  @callback delete_dir(path()) :: :ok | {:error, term()}

  # -- Convenience API (delegates to configured provider) --

  def read(path), do: provider().read(path)
  def put(path, content), do: provider().put(path, content)
  def delete(path), do: provider().delete(path)
  def delete_all(path), do: provider().delete_all(path)
  def list(path), do: provider().list(path)
  def exists?(path), do: provider().exists?(path)
  def dir?(path), do: provider().dir?(path)
  def ensure_dir(path), do: provider().ensure_dir(path)
  def delete_dir(path), do: provider().delete_dir(path)

  # -- Bang wrappers --

  def put!(path, content) do
    case provider().put(path, content) do
      :ok -> :ok
      {:error, reason} -> raise "Storage.put! failed for #{path}: #{inspect(reason)}"
    end
  end

  def ensure_dir!(path) do
    case provider().ensure_dir(path) do
      :ok -> :ok
      {:error, reason} -> raise "Storage.ensure_dir! failed for #{path}: #{inspect(reason)}"
    end
  end

  def delete_all!(path) do
    case provider().delete_all(path) do
      {:ok, files} -> files
      {:error, reason} -> raise "Storage.delete_all! failed for #{path}: #{inspect(reason)}"
    end
  end

  defp provider do
    config = Application.fetch_env!(:skill_kit, __MODULE__)
    Keyword.fetch!(config, :provider)
  end
end
