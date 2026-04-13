defmodule SkillKit.Web.DevEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :skill_kit_web

  @session_options [
    store: :cookie,
    key: "_skill_kit_web_dev",
    signing_salt: "dev_salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket

    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.Static,
    at: "/assets",
    from: {:skill_kit_web, "priv/static/assets"},
    gzip: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SkillKit.Web.Router
end
