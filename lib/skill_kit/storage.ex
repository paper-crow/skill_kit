defmodule SkillKit.Storage do
  @moduledoc """
  Behaviour and convenience API for pluggable storage backends.

  Resolves the configured provider from application config and delegates
  all operations. Providers implement the callback contract below.

  ## Configuration

      config :skill_kit, SkillKit.Storage,
        provider: SkillKit.Storage.File

  ## Callbacks

  | Callback | File equivalent | Notes |
  |----------|----------------|-------|
  | `read/1` | `File.read/1` | Returns `{:ok, binary()}` or `{:error, term()}` |
  | `put/2` | `File.write/2` | S3 PUT semantics |
  | `delete/1` | `File.rm/1` | Single file/key |
  | `delete_all/1` | `File.rm_rf/1` | Recursive delete |
  | `list/1` | `File.ls/1` | Returns `Enumerable.t()` for pagination |
  | `exists?/1` | `File.exists?/1` | |
  | `dir?/1` | `File.dir?/1` | S3 checks key prefix |
  | `ensure_dir/1` | `File.mkdir_p/1` | No-op for flat stores |
  | `delete_dir/1` | `File.rmdir/1` | Remove empty directory |
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
