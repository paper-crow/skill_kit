import Config

# Evals load the skill under test from real `SKILL.md` files on disk, but the
# test environment otherwise uses the in-memory storage backend. Opt into the
# filesystem provider for an eval run with `SKILL_KIT_STORAGE=file` so colocated
# skills resolve from disk without disturbing the rest of the suite.
if System.get_env("SKILL_KIT_STORAGE") == "file" do
  config :skill_kit, SkillKit.Storage, provider: SkillKit.Storage.File
end
