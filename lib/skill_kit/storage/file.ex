defmodule SkillKit.Storage.File do
  @moduledoc """
  Storage provider backed by the local filesystem.

  Thin wrapper around Elixir's `File` module. This is the default
  provider for development and production.
  """

  @behaviour SkillKit.Storage

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def put(path, content), do: File.write(path, content)

  @impl true
  def delete(path), do: File.rm(path)

  @impl true
  def delete_all(path), do: File.rm_rf(path)

  @impl true
  def list(path), do: File.ls(path)

  @impl true
  def exists?(path), do: File.exists?(path)

  @impl true
  def dir?(path), do: File.dir?(path)

  @impl true
  def ensure_dir(path), do: File.mkdir_p(path)

  @impl true
  def delete_dir(path), do: File.rmdir(path)
end
