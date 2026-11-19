defmodule Macus.Proxy do
  @moduledoc """
  Native Incus boundary: the shared `Opsmaru.Incus.Gateway` mounted at `/`
  and `/1.0` with Macus host policy (`Macus.Proxy.Host`) over the guest
  `incus.sock`. Per-connection workers preserve native bodies, queries,
  conditions and streams after gateway authentication, with bounded
  resources and no ambiguous mutation replay.

  Gateway identity, client-certificate trust and enrollment tokens are the
  gateway's own (`Macus.Proxy.Trust`, `Macus.Proxy.Enrollment`); the guest's certificates, addresses and trust store
  never decide or describe access.

  ## Configuration

      config :macus, Macus.Proxy,
        owner_uid: 501,
        owner_key: "macus-owner:501",
        identity: [
          origin: "https://macus.example.net:8443",
          addresses: ["macus.example.net:8443"],
          certificate_file: "/.../server/gateway.crt",
          api_extensions: ["certificate_update", ...]
        ],
        max_exchanges: 64,
        recheck_interval: 5_000,
        idle_timeout: 60_000,
        max_lifetime: 3_600_000

  plus `config :macus, :state_dir`. When serving, the running gateway's
  (`Macus.Gateway`) state directory is used, and `owner_uid`, `owner_key`
  and `identity` default to the running gateway's: its
  advertised URL and address and its certificate, with `api_extensions`
  (the verified backend's, which the shared gateway further limits to what
  it implements) taken from this configuration. `identity_scope` defaults
  to the running gateway's: `:local` for a loopback or private-network
  listener, which may advertise local addresses and names, else `:public`.
  `recheck_interval` (default and maximum 5000 ms, the documented bound)
  is how soon an active native exchange (a streamed response, WebSocket or
  raw upgrade) ends after its certificate is removed from gateway trust or
  expires: the shared gateway rechecks the grant within it, including
  callback and interruption time, and closes the exchange when it no longer
  holds. New requests are refused at once.

  `max_exchanges` (default 64) caps concurrent native exchanges, so
  saturated or idle native streams leave the listener's other connections
  for `/runtime`, `/mcp` and new authentication; one beyond it is refused
  with 503 before backend access, and a finished, failed or disconnected
  exchange returns its slot. `idle_timeout` (default 60 s, the longest
  silence in either direction) and `max_lifetime` (default 1 hour, the
  absolute budget of one exchange) end streams that stop moving or run too
  long; both are passed to the shared gateway, which also bounds bodies to
  1 GiB per stream and reads at most 64 KiB at a time.
  Without valid configuration `gateway/0` returns `:error` and every native
  request is refused with 503 before backend access.
  """

  alias Macus.Configuration
  alias Opsmaru.Incus.{Connection, Gateway}

  @admission Macus.Proxy.Admission
  # The documented revocation bound for active native exchanges.
  @recheck_interval 5_000
  @max_exchanges 64
  @idle_timeout 60_000
  @max_lifetime 3_600_000

  @doc """
  The native stream limits in effect: concurrent exchanges, idle and
  lifetime budgets and the revocation bound, in ms.
  """
  @spec limits() :: %{
          max_exchanges: pos_integer(),
          idle_timeout: pos_integer(),
          max_lifetime: pos_integer(),
          recheck_interval: pos_integer()
        }
  def limits do
    env = Application.get_env(:macus, __MODULE__, [])

    %{
      max_exchanges: Keyword.get(env, :max_exchanges, @max_exchanges),
      idle_timeout: Keyword.get(env, :idle_timeout, @idle_timeout),
      max_lifetime: Keyword.get(env, :max_lifetime, @max_lifetime),
      recheck_interval: Keyword.get(env, :recheck_interval, @recheck_interval)
    }
  end

  @doc "Admission, trust and enrollment processes for the application supervisor."
  def child_specs do
    max = limits().max_exchanges

    [
      {Gateway.Admission, name: @admission, max_exchanges: max},
      Macus.Proxy.Trust,
      Macus.Proxy.Enrollment
    ]
  end

  @doc "The gateway for the current configuration, built per request."
  @spec gateway() :: Gateway.t() | :error
  def gateway do
    env = Application.get_env(:macus, __MODULE__, [])

    serving = Macus.Gateway.current()

    with {:ok, state} <- state(serving),
         uid when is_integer(uid) and uid >= 0 <-
           Keyword.get(env, :owner_uid, serving && serving.uid),
         key when is_binary(key) <-
           Keyword.get_lazy(env, :owner_key, fn -> uid && Macus.Auth.owner_key(uid) end),
         identity when is_list(identity) <- Keyword.get_lazy(env, :identity, &serving_identity/0) do
      connection =
        Connection.unix!(Path.join(state.state_dir, "incus.sock"), owner: {:macus, key})

      limits = limits()

      Gateway.new!(
        connection: connection,
        host: Macus.Proxy.Host,
        host_config: %{
          store: %{state: state, uid: uid},
          identity: identity,
          connection: connection,
          clock: Keyword.get(env, :clock),
          image_grant_ttl: limits.max_lifetime
        },
        admission: @admission,
        recheck_interval: limits.recheck_interval,
        idle_timeout: limits.idle_timeout,
        max_lifetime: limits.max_lifetime,
        identity_scope:
          Keyword.get_lazy(env, :identity_scope, fn ->
            Macus.Gateway.identity_scope() || :public
          end)
      )
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The running gateway's own state directory is authoritative.
  defp state(%Macus.Gateway{state: state}), do: {:ok, state}
  defp state(nil), do: Configuration.new(Application.get_env(:macus, :state_dir))

  # The running gateway's public identity with the configured verified
  # backend extensions.
  defp serving_identity do
    case Macus.Gateway.identity() do
      nil ->
        nil

      identity ->
        extensions =
          Keyword.get(Application.get_env(:macus, __MODULE__, []), :api_extensions, [])

        identity ++ [api_extensions: extensions]
    end
  end
end
