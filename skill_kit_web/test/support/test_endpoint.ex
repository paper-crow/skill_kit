defmodule SkillKitWeb.TestEndpoint do
  use Phoenix.Endpoint, otp_app: :skill_kit_web

  @session_options [
    store: :cookie,
    key: "_skill_kit_web_key",
    signing_salt: "test_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(SkillKit.Web.Router)
end
