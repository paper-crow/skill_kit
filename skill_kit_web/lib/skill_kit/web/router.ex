defmodule SkillKit.Web.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SkillKit.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SkillKit.Web do
    pipe_through(:browser)

    live("/setup", OnboardingLive, :new)
    live("/setup/:conversation_id", OnboardingLive, :show)
    live("/", EditorLive, :index)
    live("/*path", EditorLive, :show)
  end

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:skill_kit_web, Map.new(opts))
    |> super(opts)
  end
end
