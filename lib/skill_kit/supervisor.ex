defmodule SkillKit.Supervisor do
  @moduledoc """
  The OTP Supervisor for SkillKit.

  `SkillKit.Supervisor` is the primary integration surface for host applications.
  Add it to your supervision tree to start and supervise the skill registry.

  ## Usage

  The simplest integration uses default names:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {SkillKit.Supervisor, []}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  To use a custom registry name (useful in umbrella apps or multi-tenant setups):

      children = [
        {SkillKit.Supervisor, registry_name: MyApp.SkillRegistry}
      ]

  To auto-load skills from directories at boot:

      children = [
        {SkillKit.Supervisor,
          registry_name: MyApp.SkillRegistry,
          skill_dirs: [Path.join(Application.app_dir(:my_app), "priv/skills")]}
      ]

  To auto-register code skill modules at boot:

      children = [
        {SkillKit.Supervisor,
          registry_name: MyApp.SkillRegistry,
          skills: [MyApp.Skills.Search, MyApp.Skills.Summarize]}
      ]

  ## Supervision Strategy

  Uses `:one_for_one` with a single child (`SkillKit.Registry`). `SkillKit.Loader`
  is a pure module (not a process) so it does not appear in the supervision tree.

  ## Options

  - `:name` — the name to register the Supervisor process under. Defaults to
    `SkillKit.Supervisor`.

  - `:registry_name` — the name to pass to `SkillKit.Registry.start_link/1`.
    Defaults to `SkillKit.Registry`. Override this when running multiple
    SkillKit instances in the same node (e.g., in tests or umbrella apps).

  - `:skill_dirs` — list of directory paths to scan for `.skill.md` files at
    boot. Scanning is recursive. Malformed files are skipped with a warning.
    Defaults to `[]`.

  - `:skills` — list of module atoms implementing the `SkillKit.Skill` behaviour
    to register at boot. Each module is validated before registration.
    Defaults to `[]`.
  """

  use Supervisor

  @doc """
  Starts a SkillKit.Supervisor process linked to the current process.

  ## Options

  - `:name` — the name to register the Supervisor under. Defaults to `__MODULE__`.
  - `:registry_name` — the name for the child `SkillKit.Registry`. Defaults to
    `SkillKit.Registry`.
  - `:skill_dirs` — list of directory paths to scan for `.skill.md` files at boot.
  - `:skills` — list of module atoms implementing `SkillKit.Skill` to register at boot.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, SkillKit.Registry)
    skill_dirs = Keyword.get(opts, :skill_dirs, [])
    skills = Keyword.get(opts, :skills, [])

    children = [
      {SkillKit.Registry,
       name: registry_name, skill_dirs: skill_dirs, skills: skills}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
