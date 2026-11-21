import Config

config :logger, level: :info

# The immutable source revision this release is built from, recorded at
# build time (Macus.Build).
config :macus, Macus.Build,
  revision: System.get_env("MACUS_SOURCE_REVISION"),
  cassette_sha256: System.get_env("MACUS_CASSETTE_SHA256")
