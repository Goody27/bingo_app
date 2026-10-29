defmodule BingoAppWeb.Router do
  use BingoAppWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BingoAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # participant_id をセッションに用意する（LiveView の mount で受け取る）
    plug BingoAppWeb.Plugs.VisitorId
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BingoAppWeb do
    pipe_through :browser

    live "/", RoomLive.Index, :index
    live "/rooms/:id", RoomLive.Show, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", BingoAppWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:bingo_app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BingoAppWeb.Telemetry
    end
  end
end
