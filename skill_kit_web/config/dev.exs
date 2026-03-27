import Config

config :skill_kit_web, SkillKit.Web.DevEndpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [port: 4040],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev_secret_key_base_", 4),
  live_view: [signing_salt: "dev_salt"],
  server: true,
  watchers: [
    tailwindcss: {Tailwind, :install_and_run, [:skill_kit_web, ~w(--watch)]},
    esbuild: {Esbuild, :install_and_run, [:skill_kit_web, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"lib/skill_kit/web/.*(ex|heex)$",
      ~r"priv/static/.*(js|css)$"
    ]
  ]

config :skill_kit_web, :project_root, File.cwd!()

config :esbuild,
  version: "0.24.2",
  skill_kit_web: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.17",
  skill_kit_web: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]
