defmodule SkillKitWeb do
  @moduledoc """
  A Phoenix plug that mounts a collaborative document editor
  into any Phoenix application, powered by SkillKit.

  All paths derive from a single `:project_root` configuration
  pointing at the host application's repository. Set it via:

      config :skill_kit_web, :project_root, "/path/to/my_app"

  Or via the `SKILL_KIT_PROJECT` environment variable.

  ## Derived paths

    * `docs_root` — `project_root/docs` (override with `:docs_root`)
    * `conversations_dir` — `project_root/.skill_kit/conversations`
    * `agents_dir` — `project_root/.skill_kit/agents` (falls back to built-in)
    * `build_root` — `docs_root/.build`
  """

  @doc """
  Returns the configured project root directory.

  Resolution order:
  1. Application env `:project_root`
  2. `SKILL_KIT_PROJECT` environment variable
  3. `File.cwd!/0`
  """
  def project_root do
    Application.get_env(:skill_kit_web, :project_root) ||
      System.get_env("SKILL_KIT_PROJECT") ||
      File.cwd!()
  end

  @doc """
  Returns the docs root directory where markdown documents live.
  Defaults to `docs/` within the project root.
  """
  def docs_root do
    configured = Application.get_env(:skill_kit_web, :docs_root, "docs")

    if Path.type(configured) == :absolute do
      configured
    else
      Path.join(project_root(), configured)
    end
  end

  @doc """
  Returns the directory for BuilderKit artifacts (requirements, plans).
  Located at `.build/` within the docs root.
  """
  def build_root do
    Path.join(docs_root(), ".build")
  end

  @doc """
  Returns the directory for persisting conversation history.
  Located at `.skill_kit/conversations` within the project root.
  """
  def conversations_dir do
    Path.join(project_root(), ".skill_kit/conversations")
  end

  @doc """
  Returns the path to the agent definition file.

  Checks for a project-specific agent at
  `project_root/.skill_kit/agents/assistant.md` first,
  then falls back to the built-in agent shipped with SkillKit Web.
  """
  def agent_path do
    project_agent = Path.join(project_root(), ".skill_kit/agents/assistant.md")

    if File.exists?(project_agent) do
      project_agent
    else
      Application.app_dir(:skill_kit_web, "priv/agents/assistant.md")
    end
  end
end
