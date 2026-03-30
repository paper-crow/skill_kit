import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic
  ],
  default_provider: :anthropic

config :skill_kit, :hook_handlers, %{
  "command" => SkillKit.Hooks.Command,
  "http" => SkillKit.Hooks.Http
}

config :skill_kit, SkillKit.Storage, provider: SkillKit.Storage.File

import_config "#{config_env()}.exs"
