defmodule SkillKit.RegistryTest.OverlappingBackend do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_skills(_config) do
    {:ok, [
      %SkillKit.Skill{
        name: "files:summarize",
        namespace: "files",
        description: "Overlapping description",
        body: "Different body"
      }
    ]}
  end
end

defmodule SkillKit.RegistryTest.FailingBackend do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_skills(_config) do
    {:error, :database_unavailable}
  end
end

defmodule SkillKit.TestBackends.SkillsOnly do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_skills(_config), do: {:ok, []}
end
