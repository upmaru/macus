# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :macus,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :macus, MacusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: MacusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Macus.PubSub,
  server: false

# Native Incus extensions the gateway advertises for the guest. Each is a
# protocol Macus mounts (REST, WebSocket and raw upgrades), and the shared
# gateway serves only those it implements: authenticated `/1.0` further
# keeps only those the guest reports. The copy extensions let a client
# holding this gateway and another server copy instances (container_push*),
# custom volumes (storage_api_*_volume_handling) and images
# (images_push_relay) between them; the servers dial the gateway with
# operation or image secrets, which `Macus.Proxy.Host` admits.
# api_filtering and instance_get_full are query-parameter features the
# standard client needs to list instances (upmaru/opsmaru-incus#85).
config :macus, Macus.Proxy,
  api_extensions: [
    "certificate_update",
    "instances",
    "api_filtering",
    "instance_get_full",
    "file_delete",
    "console",
    "instance_nbd",
    "custom_volume_sftp",
    "storage_volume_nbd",
    "container_push",
    "container_push_target",
    "storage_api_local_volume_handling",
    "storage_api_remote_volume_handling",
    "images_push_relay"
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Never log credentials: parameters whose names contain these are [FILTERED].
config :phoenix, :filter_parameters, ["password", "secret", "token", "key"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
