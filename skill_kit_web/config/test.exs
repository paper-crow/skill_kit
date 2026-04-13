import Config

config :skill_kit_web, SkillKitWeb.TestEndpoint,
  http: [port: 4002],
  server: false,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"]

# Tests override docs_root per-test via Application.put_env.
# Set a safe project_root so no test accidentally writes to cwd.
config :skill_kit_web, :project_root, Path.expand("../test/tmp", __DIR__)
