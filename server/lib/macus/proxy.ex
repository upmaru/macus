defmodule Macus.Proxy do
  @moduledoc """
  Native Incus boundary: the shared `Opsmaru.Incus.Gateway` mounted at `/`
  and `/1.0` with Macus host policy (`Macus.Proxy.Host`) over the guest
  `incus.sock`. Per-connection workers preserve native bodies, queries,
  conditions and streams after gateway authentication, with bounded
  resources and no ambiguous mutation replay.

  Gateway identity and client-certificate trust are the gateway's own
  (`Macus.Proxy.Trust`); the guest's certificates, addresses and trust store
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
        max_exchanges: 64

  plus `config :macus, :state_dir`. The identity comes from the private
  gateway endpoint metadata (task 3.1); `api_extensions` are the verified
  backend's, which the shared gateway further limits to what it implements.
  Without valid configuration `gateway/0` returns `:error` and every native
  request is refused with 503 before backend access.
  """

  alias Macus.Configuration
  alias Opsmaru.Incus.{Connection, Gateway}

  @admission Macus.Proxy.Admission

  @doc "Admission and trust-store processes for the application supervisor."
  def child_specs do
    max = Keyword.get(Application.get_env(:macus, __MODULE__, []), :max_exchanges, 64)

    [
      {Gateway.Admission, name: @admission, max_exchanges: max},
      Macus.Proxy.Trust
    ]
  end

  @doc "The gateway for the current configuration, built per request."
  @spec gateway() :: Gateway.t() | :error
  def gateway do
    env = Application.get_env(:macus, __MODULE__, [])

    with {:ok, state} <- Configuration.new(Application.get_env(:macus, :state_dir)),
         uid when is_integer(uid) and uid >= 0 <- Keyword.get(env, :owner_uid),
         key when is_binary(key) <- Keyword.get(env, :owner_key),
         identity when is_list(identity) <- Keyword.get(env, :identity) do
      connection =
        Connection.unix!(Path.join(state.state_dir, "incus.sock"), owner: {:macus, key})

      Gateway.new!(
        connection: connection,
        host: Macus.Proxy.Host,
        host_config: %{
          store: %{state: state, uid: uid},
          identity: identity,
          connection: connection,
          clock: Keyword.get(env, :clock)
        },
        admission: @admission
      )
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
