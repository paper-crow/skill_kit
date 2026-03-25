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

  To auto-load skills from directories at boot using skills:

      children = [
        {SkillKit.Supervisor,
          registry_name: MyApp.SkillRegistry,
          skills: [{SkillKit.Kit.Local, dirs: ["priv/skills"]}]}
      ]

  ## Supervision Strategy

  Uses `:one_for_one` with a single child (`SkillKit.Registry`).

  ## Options

  - `:name` — the name to register the Supervisor process under. Defaults to
    `SkillKit.Supervisor`.

  - `:registry_name` — the name to pass to `SkillKit.Registry.start_link/1`.
    Defaults to `SkillKit.Registry`. Override this when running multiple
    SkillKit instances in the same node (e.g., in tests or umbrella apps).

  - `:skills` — list of `{module, keyword()}` provider configurations. Each
    provider implements `SkillKit.Kit.Provider` and is called at boot to load skills.
    Defaults to `[]`.
  """

  use Supervisor

  @doc """
  Starts a SkillKit.Supervisor process linked to the current process.

  ## Options

  - `:name` — the name to register the Supervisor under. Defaults to `__MODULE__`.
  - `:registry_name` — the name for the child `SkillKit.Registry`. Defaults to
    `SkillKit.Registry`.
  - `:skills` — list of `{module, keyword()}` provider configurations. Each provider
    implements `SkillKit.Kit.Provider` and is called at boot to load skills. Defaults to `[]`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, SkillKit.Registry)
    skills = Keyword.get(opts, :skills, [])
    kits = Keyword.get(opts, :kits)

    registry_opts = [name: registry_name, skills: skills, kits: kits]

    children = [
      {SkillKit.Registry, registry_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
