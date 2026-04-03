defmodule SkillKit.Web.Agents do
  @moduledoc """
  Starts pre-configured SkillKit agents for web UI contexts.

  Encapsulates agent resolution, scope construction, skill wiring, and
  conversation store setup so that LiveViews only need to call a single
  function. All infrastructure (paths, scope, store) is derived from
  `SkillKitWeb` configuration.

  Uses `LiveConversationStore` which notifies the caller on load/save,
  so LiveViews receive `{:conversation_loaded, messages}` and
  `{:conversation_saved, messages}` to stay in sync with the agent.

  ## Usage

      {:ok, agent_ref} = Agents.start_assistant(self())
      {:ok, agent_ref} = Agents.start_onboarding(self(), "onboarding-abc123")
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Web.BuilderKit
  alias SkillKit.Web.DocumentKit
  alias SkillKit.Web.EditorScope
  alias SkillKit.Web.LiveConversationStore
  alias SkillKit.Web.OnboardingKit

  @doc """
  Starts the project assistant agent (editor chat).

  Uses the project-specific agent definition if present, otherwise falls
  back to the built-in assistant. Includes DocumentKit and BuilderKit skills.
  """
  @spec start_assistant(pid()) :: {:ok, SkillKit.agent()} | {:error, term()}
  def start_assistant(caller) do
    start_agent(SkillKitWeb.agent_path(),
      caller: caller,
      skills: [{DocumentKit, []}, {BuilderKit, []}],
      scope: default_scope(caller)
    )
  end

  @doc """
  Starts the onboarding agent for new project setup.

  The `conversation_id` is used as the agent name, which makes the
  conversation store persist and resume under that ID.
  """
  @spec start_onboarding(pid(), String.t()) :: {:ok, SkillKit.agent()} | {:error, term()}
  def start_onboarding(caller, conversation_id) do
    start_kit(OnboardingKit,
      caller: caller,
      skills: [{DocumentKit, []}],
      name: conversation_id,
      scope: default_scope(caller)
    )
  end

  # -- Internal ----------------------------------------------------------------

  defp start_agent(agent_path, opts) do
    case Definition.parse(agent_path) do
      {:ok, definition} -> start_agent_from_definition(definition, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_kit(kit_module, opts) do
    caller = Keyword.fetch!(opts, :caller)
    all_opts = Keyword.put(opts, :conversation_store, conversation_store(caller))
    SkillKit.start_agent(kit_module, all_opts)
  end

  defp start_agent_from_definition(definition, opts) do
    caller = Keyword.fetch!(opts, :caller)
    all_opts = Keyword.put(opts, :conversation_store, conversation_store(caller))
    SkillKit.start_agent(definition, all_opts)
  end

  defp default_scope(caller) do
    %EditorScope{
      caller: caller,
      project_root: SkillKitWeb.project_root(),
      docs_root: SkillKitWeb.docs_root()
    }
  end

  defp conversation_store(caller) do
    {LiveConversationStore, dir: SkillKitWeb.conversations_dir(), caller: caller}
  end
end
