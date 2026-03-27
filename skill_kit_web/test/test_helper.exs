Application.put_env(:skill_kit_web, SkillKitWeb.TestEndpoint,
  http: [port: 4002],
  server: false,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test_salt"]
)

{:ok, _} = SkillKitWeb.TestEndpoint.start_link()

ExUnit.start()
