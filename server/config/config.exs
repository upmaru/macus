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

# Native Incus extensions the gateway advertises for the guest. The shared
# gateway serves only those it implements (opsmaru_incus's
# `Opsmaru.Incus.Gateway.Identity`), and authenticated `/1.0` further keeps
# only those the guest reports. The standard `incus` client refuses a command
# whose extension the server does not advertise, so every feature of a route
# the gateway relays must be named here (upmaru/opsmaru-incus#94).
#
# Excluded on purpose, and refused by the gateway anyway: clustering (the
# gateway fronts one guest), certificate_token (trust tokens are issued by
# Macus, not the guest), metrics (metrics trust), project_access and
# instance_access (access reports name guest-side identities) and
# console_vga_type (the VGA console needs SPICE, which is not relayed).
# Discovery, trust and instances. api_filtering and instance_get_full let
# `incus list` work (upmaru/opsmaru-incus#85); instance_create_start stops
# `incus launch` starting the instance twice (upmaru/opsmaru-incus#88).
base = ~w(certificate_update instances api_filtering instance_get_full
          instance_create_start file_delete)

projects = ~w(projects project_usage projects_force_delete container_copy_project
              instance_project_move storage_volume_project_move)

all_projects = ~w(images_all_projects instance_all_projects network_acls_all_projects
                  network_zones_all_projects networks_all_projects
                  operations_get_query_all_projects profiles_all_projects
                  storage_buckets_all_projects storage_volumes_all_projects)

storage = ~w(storage storage_api_project storage_api_volume_rename
             storage_api_volume_snapshots storage_volume_full storage_volume_state
             storage_volumes_rebuild custom_volume_refresh
             custom_volume_refresh_exclude_older_snapshots storage_buckets
             storage_bucket_full storage_buckets_create_credentials instance_pool_move)

networks = ~w(network network_acl network_acl_log network_address_set network_allocations
              network_dns network_dns_records network_forward network_integrations
              network_leases network_load_balancer network_load_balancer_state
              network_peer network_state instance_nic_network)

# Instances, files and snapshots
instances = ~w(container_full container_edit_metadata container_exec_user_group_cwd
               container_exec_recording dependent directory_manipulation file_append
               file_symlinks instance_bulk_state_change instance_move_config
               instance_snapshot_disk_only_restore instances_rebuild instances_debug_repair
               snapshot_expiry snapshot_expiry_creation)

copy_options = ~w(container_incremental_copy container_only_migration
                  instance_allow_inconsistent_copy)

images = ~w(image_compression_algorithm image_copy_profile image_create_aliases
            image_force_refresh)

server_info = ~w(resources resources_v2 warnings metadata_configuration)

# Backups and ISO volumes. Bodies are bounded by the gateway's
# max_stream_bytes (1 GiB by default), so larger backup uploads and exports
# fail at that limit.
backups = ~w(container_backup container_backup_override_pool backup_override_config
             backup_override_name custom_volume_backup storage_bucket_backup direct_backup
             custom_volume_iso)

# The operation WebSocket: console streams and migration. The copy extensions
# let a client holding this gateway and another server copy instances
# (container_push*), custom volumes (storage_api_*_volume_handling) and images
# (images_push_relay) between them; the servers dial the gateway with
# operation or image secrets, which `Macus.Proxy.Host` admits.
websocket = ~w(console console_force container_push container_push_target
               container_snapshot_stateful_migration storage_api_local_volume_handling
               storage_api_remote_volume_handling storage_api_remote_volume_snapshot_copy
               images_push_relay)

raw_upgrades = ~w(instance_nbd custom_volume_sftp storage_volume_nbd)

config :macus, Macus.Proxy,
  api_extensions:
    Enum.concat([
      base,
      projects,
      all_projects,
      storage,
      networks,
      instances,
      copy_options,
      images,
      server_info,
      backups,
      websocket,
      raw_upgrades
    ])

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
