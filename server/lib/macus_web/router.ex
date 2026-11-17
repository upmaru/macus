defmodule MacusWeb.Router do
  use MacusWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", MacusWeb do
    pipe_through :api
  end

  # MCP owns its body framing and authentication; no pipeline runs first.
  forward "/mcp", MacusWeb.MCP

  # Native Incus: the shared gateway owns framing, authentication, identity
  # and trust before any backend access; no pipeline or body parser runs.
  get "/", Opsmaru.Incus.Gateway.Plug, gateway: {Macus.Proxy, :gateway, []}
  forward "/1.0", Opsmaru.Incus.Gateway.Plug, gateway: {Macus.Proxy, :gateway, []}
end
