import Config

# The Phoenix endpoint never listens by itself. PHX_SERVER and PORT enable
# nothing; the only public listener is Macus.Gateway's TLS listener.
config :macus, MacusWeb.Endpoint, server: false

# Resolve selected state passively. The gateway validates it before any access.
state_dir =
  System.get_env("MACUS_STATE_DIR") || System.get_env("TIM_STATE_DIR") ||
    Path.expand("~/.tama/incus-mac")

config :macus, :state_dir, state_dir

# A release serves only when its launcher asks for it explicitly and names
# the Swift component's source revision, which must equal this build's.
if config_env() == :prod do
  config :macus, Macus.Gateway,
    serve: System.get_env("MACUS_SERVE") == "1",
    expected_revision: System.get_env("MACUS_EXPECTED_REVISION")
end
