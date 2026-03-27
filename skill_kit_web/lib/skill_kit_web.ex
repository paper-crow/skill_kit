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
end
