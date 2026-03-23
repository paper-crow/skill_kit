import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic
  ],
  default_provider: :anthropic

import_config "#{config_env()}.exs"
