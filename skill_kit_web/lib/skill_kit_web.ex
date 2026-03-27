defmodule SkillKitWeb do
  @moduledoc """
  A Phoenix plug that mounts a collaborative document editor
  into any Phoenix application, powered by SkillKit.
  """

  @doc """
  Returns the configured project root directory.
  Falls back to `File.cwd!/0` if not configured.
  """
  def project_root do
    Application.get_env(:skill_kit_web, :project_root, File.cwd!())
  end

  @doc """
  Returns the configured docs root directory.

  This is where the editor looks for markdown documents.
  Defaults to `guides/` within the project root.
  Can be configured as an absolute path or relative to the project root.
  """
  def docs_root do
    configured = Application.get_env(:skill_kit_web, :docs_root, "guides")

    if Path.type(configured) == :absolute do
      configured
    else
      Path.join(project_root(), configured)
    end
  end
end
