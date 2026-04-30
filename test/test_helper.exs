ExUnit.start(exclude: [:e2e, :external_fixture])
Mox.defmock(SkillKit.LLM.Mock, for: SkillKit.LLM)
Mox.defmock(SkillKit.CredentialProvider.Mock, for: SkillKit.CredentialProvider)
Application.put_env(:skill_kit, :credential_provider, SkillKit.CredentialProvider.Mock)
