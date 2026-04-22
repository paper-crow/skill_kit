import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic,
    mock: SkillKit.LLM.Mock
  ],
  default_provider: :mock

config :skill_kit, SkillKit.Storage, provider: SkillKit.Storage.Memory

config :skill_kit, :credential_provider, SkillKit.CredentialProvider.Mock
