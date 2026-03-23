import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic,
    mock: SkillKit.LLM.Mock
  ],
  default_provider: :mock
