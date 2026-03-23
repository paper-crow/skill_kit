defmodule SkillKit.RegistryTest.OverlappingBackend do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_kits(_config) do
    {:ok,
     [
       %SkillKit.Kit{
         name: "overlapping",
         skills: [
           %SkillKit.Skill{
             name: "files:summarize",
             namespace: "files",
             description: "Overlapping description",
             body: "Different body"
           }
         ]
       }
     ]}
  end
end

defmodule SkillKit.RegistryTest.FailingBackend do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_kits(_config) do
    {:error, :database_unavailable}
  end
end

defmodule SkillKit.TestBackends.SkillsOnly do
  @moduledoc false
  @behaviour SkillKit.Backend

  @impl true
  def load_kits(_config), do: {:ok, [%SkillKit.Kit{name: "empty"}]}
end
