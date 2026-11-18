defmodule Macus.Gateway do
  @moduledoc """
  The public HTTPS listener and its private state under `<state-dir>/server/`.

  ## Serving

  The listener starts only when the release is told to serve,

      config :macus, Macus.Gateway,
        serve: true,
        expected_revision: "<the Swift component's source revision>",
        owner_uid: 501

  which `config/runtime.exs` sets from `MACUS_SERVE=1` and
  `MACUS_EXPECTED_REVISION` in production. `owner_uid` defaults to the
  user running the server. `PHX_SERVER` and `PORT` enable nothing, and
  without `serve` the application opens no listener and touches no state.

  ## Preflight

  Before anything listens, `prepare/1` checks, in order and without
  contacting either private Swift socket:

  1. the build: its source revision is known and equals the expected one,
     and the loaded `:opsmaru_incus` is the locked version (`Macus.Build`);
  2. the state directory: an existing directory of the owner that nobody
     else can write, below safe ancestors (Swift creates it);
  3. the gateway directory `<state-dir>/server`: owner-private (0700),
     created only when absent;
  4. the listener configuration (`Macus.Gateway.Config`);
  5. the TLS identity (`Macus.Gateway.Certificate`). The default identity
     is generated once, only when neither file exists and no endpoint was
     ever published; an incomplete or vanished identity is an error, never
     silently replaced.

  Any failure stops the application from starting, so there is no
  fallback to cleartext, another address or another identity.

  ## Listener

  One Cowboy TLS listener on the configured address and port: TLS 1.3
  only, HTTP/1.1, and any client certificate collected without being
  trusted (no acceptable-CA names are sent, or Go clients would withhold
  self-signed certificates). Trust is decided per request by
  `Macus.Proxy.Host` and bearer verification, not by the handshake. An
  occupied port fails startup; ranch's `SO_REUSEADDR` does not let it share
  an address another socket is listening on.

  ## Endpoint metadata

  Once listening, the gateway atomically replaces the owner-private
  `<state-dir>/server/endpoint.json`:

      {
        "schema_version": 1,
        "url": "https://127.0.0.1:8443",
        "addresses": ["127.0.0.1:8443"],
        "listen": "127.0.0.1:8443",
        "certificate": "-----BEGIN CERTIFICATE-----...",
        "certificate_fingerprint": "<sha256 hex>",
        "pid": "12345",
        "started_at": "2026-11-18T10:00:00Z",
        "build": {
          "version": "0.1.0",
          "revision": "<source revision>",
          "opsmaru_incus": {"version": "0.2.2", "checksum": "<hex>"}
        }
      }

  Clients pin `certificate` and compare `build` with their own identity.
  A stopped server leaves its last metadata in place; liveness is proved by
  connecting. Each state directory has its own metadata, so an isolated
  state never replaces the default one.
  """

  require Logger

  alias Macus.{Build, Configuration, PrivatePath}
  alias Macus.Gateway.{Certificate, Config}
  @listener __MODULE__.Listener
  @current {__MODULE__, :current}
  @metadata "endpoint.json"

  @enforce_keys [:state, :uid, :config, :certificate, :build]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: Configuration.t(),
          uid: non_neg_integer(),
          config: Config.t(),
          certificate: Certificate.t(),
          build: Build.identity()
        }

  @doc """
  The gateway children for the application supervisor: none unless serving,
  otherwise the listener and the endpoint publisher, after a successful
  preflight.
  """
  @spec children() :: {:ok, [Supervisor.child_spec() | {module(), term()}]} | {:error, term()}
  def children do
    env = Application.get_env(:macus, __MODULE__, [])

    if Keyword.get(env, :serve, false) == true do
      with {:ok, state} <- Configuration.new(Application.get_env(:macus, :state_dir)),
           {:ok, uid} <- owner_uid(env),
           {:ok, gateway} <-
             prepare(
               state: state,
               uid: uid,
               expected_revision: Keyword.get(env, :expected_revision),
               now: DateTime.utc_now()
             ) do
        {:ok, [listener(gateway), {__MODULE__.Publisher, gateway}]}
      end
    else
      {:ok, []}
    end
  end

  defp owner_uid(env) do
    case Keyword.get(env, :owner_uid) do
      uid when is_integer(uid) and uid >= 0 -> {:ok, uid}
      nil -> process_uid()
      _ -> {:error, :invalid_owner}
    end
  end

  defp process_uid do
    case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output |> String.trim() |> String.to_integer()}
      _ -> {:error, :invalid_owner}
    end
  rescue
    _ -> {:error, :invalid_owner}
  end

  @doc """
  Runs the serving preflight (see the module documentation). Options:
  `:state` (`Macus.Configuration`), `:uid`, `:expected_revision`, `:now`.
  """
  @spec prepare(keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(opts) do
    %Configuration{} = state = Keyword.fetch!(opts, :state)
    uid = Keyword.fetch!(opts, :uid)
    now = Keyword.fetch!(opts, :now)

    with :ok <- Build.check(Keyword.get(opts, :expected_revision)),
         :ok <- state_dir(state.state_dir, uid),
         :ok <- gateway_dir(Configuration.gateway_dir(state), uid),
         {:ok, config} <- Config.load(state, uid),
         :ok <- default_identity(state, config, now),
         {:ok, certificate} <- Certificate.load(config, uid, config.host, now) do
      {:ok,
       %__MODULE__{
         state: state,
         uid: uid,
         config: config,
         certificate: certificate,
         build: Build.identity()
       }}
    end
  end

  defp state_dir(path, uid) do
    real = PrivatePath.system_alias(path)

    case File.lstat(real) do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} ->
        if Bitwise.band(mode, 0o022) == 0 and
             PrivatePath.safe_ancestors(Path.dirname(real), uid) == :ok,
           do: :ok,
           else: {:error, :unsafe_state}

      {:error, :enoent} ->
        {:error, :missing_state}

      _ ->
        {:error, :unsafe_state}
    end
  end

  defp gateway_dir(path, uid) do
    case PrivatePath.private_dir(path, uid) do
      :ok ->
        :ok

      {:error, :enoent} ->
        with :ok <- mkdir(path),
             :ok <- PrivatePath.private_dir(path, uid) do
          :ok
        else
          _ -> {:error, :unsafe_state}
        end

      {:error, :unsafe} ->
        {:error, :unsafe_state}
    end
  end

  defp mkdir(path) do
    case :file.make_dir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp default_identity(_state, %Config{default_identity: false}, _now), do: :ok

  defp default_identity(state, %Config{certfile: certfile, keyfile: keyfile}, now) do
    case {exists?(certfile), exists?(keyfile), exists?(metadata_path(state))} do
      {true, true, _} ->
        :ok

      {false, false, false} ->
        case Certificate.generate(certfile, keyfile, now) do
          :ok -> :ok
          {:error, _} -> {:error, :identity_unwritable}
        end

      {false, false, true} ->
        {:error, :identity_missing}

      _ ->
        {:error, :identity_incomplete}
    end
  end

  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  @doc "The Ranch listener child for a prepared gateway."
  @spec listener(t()) :: Supervisor.child_spec()
  def listener(%__MODULE__{config: config, certificate: certificate}) do
    dispatch =
      :cowboy_router.compile([{:_, [{:_, Plug.Cowboy.Handler, {MacusWeb.Endpoint, []}}]}])

    transport = %{
      num_acceptors: 8,
      max_connections: 1024,
      connection_type: :supervisor,
      socket_opts: [
        ip: config.bind_ip,
        port: config.port,
        certfile: String.to_charlist(config.certfile),
        keyfile: String.to_charlist(config.keyfile),
        # OTP needs a CA list to request a client certificate; the
        # verify_fun accepts any certificate and none of these names is
        # advertised, so the list only satisfies that requirement.
        cacerts: [certificate.der],
        certificate_authorities: false,
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        verify_fun: {&__MODULE__.collect_peer/3, nil},
        versions: [:"tlsv1.3"],
        alpn_preferred_protocols: ["http/1.1"]
      ]
    }

    protocol = %{env: %{dispatch: dispatch}, connection_type: :supervisor, dynamic_buffer: false}

    @listener
    |> :ranch.child_spec(:ranch_ssl, transport, :cowboy_tls, protocol)
    |> Supervisor.child_spec(id: @listener)
  end

  @doc false
  # Collects any client certificate; it is trusted only by later checks.
  def collect_peer(_certificate, {:bad_cert, _reason}, state), do: {:valid, state}
  def collect_peer(_certificate, {:extension, _extension}, state), do: {:unknown, state}
  def collect_peer(_certificate, _event, state), do: {:valid, state}

  @doc "The listening port of the running listener."
  @spec port() :: :inet.port_number()
  def port, do: :ranch.get_port(@listener)

  @spec metadata_path(Configuration.t()) :: String.t()
  def metadata_path(%Configuration{} = state),
    do: Path.join(Configuration.gateway_dir(state), @metadata)

  @doc "Atomically publishes the endpoint metadata of a listening gateway."
  @spec publish(t(), DateTime.t()) :: :ok | {:error, :unwritable}
  def publish(%__MODULE__{} = gateway, now) do
    %{config: config, certificate: certificate, build: build} = gateway

    metadata = %{
      "schema_version" => 1,
      "url" => config.url,
      "addresses" => [config.address],
      "listen" => listen_address(config),
      "certificate" => certificate.pem,
      "certificate_fingerprint" => certificate.fingerprint,
      "pid" => System.pid(),
      "started_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "build" => %{
        "version" => build.version,
        "revision" => build.revision,
        "opsmaru_incus" => %{
          "version" => build.opsmaru_incus.version,
          "checksum" => build.opsmaru_incus.checksum
        }
      }
    }

    PrivatePath.replace(metadata_path(gateway.state), Jason.encode_to_iodata!(metadata))
  end

  defp listen_address(%Config{bind_ip: ip, port: port}) do
    host = ip |> :inet.ntoa() |> to_string()
    if tuple_size(ip) == 8, do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  @doc "The running gateway, or nil when not serving."
  @spec current() :: t() | nil
  def current, do: :persistent_term.get(@current, nil)

  @doc false
  def put_current(gateway), do: :persistent_term.put(@current, gateway)

  @doc false
  def clear_current, do: :persistent_term.erase(@current)

  @doc """
  The public native identity of the running gateway for `Macus.Proxy`:
  origin, advertised addresses and the leaf certificate.
  """
  @spec identity() :: keyword() | nil
  def identity do
    case current() do
      %__MODULE__{config: config, certificate: certificate} ->
        [origin: config.url, addresses: [config.address], certificate: certificate.pem]

      nil ->
        nil
    end
  end

  @doc """
  The shared gateway identity scope of the running gateway
  (`Macus.Gateway.Config.identity_scope/1`), or nil when not serving.
  """
  @spec identity_scope() :: :local | :public | nil
  def identity_scope do
    case current() do
      %__MODULE__{config: config} -> Config.identity_scope(config)
      nil -> nil
    end
  end

  @doc "A one-line explanation of a preflight failure for the server log."
  @spec describe(term()) :: String.t()
  def describe(:missing_revision),
    do: "the server build or its launcher does not record a source revision"

  def describe(:revision_mismatch),
    do: "the server and Swift components come from different source revisions; reinstall Macus"

  def describe(:dependency_mismatch),
    do: "the bundled opsmaru_incus is not the version this server was built with; reinstall Macus"

  def describe(:missing_state), do: "the state directory does not exist; run macus start"

  def describe(:unsafe_state),
    do:
      "the state or gateway directory is not owned by this user, is writable by others or has unsafe ancestors"

  def describe(:unsafe_configuration),
    do: "server/gateway.json must be a 0600 file owned by this user"

  def describe({:invalid_configuration, field}), do: "server/gateway.json has an invalid #{field}"

  def describe(:wildcard_bind),
    do: "server/gateway.json binds every interface; name one address instead"

  def describe(:advertised_url_required),
    do: "a non-loopback bind_address needs an explicit advertised_url"

  def describe(:identity_missing),
    do: "the gateway certificate or key is missing; it is not regenerated automatically"

  def describe(:identity_incomplete), do: "only one of gateway.crt and gateway.key exists"
  def describe(:identity_unwritable), do: "the gateway identity could not be created"
  def describe(:unsafe_certificate), do: "the gateway certificate file is not safely owned"
  def describe(:invalid_certificate), do: "the gateway certificate file is not a PEM certificate"
  def describe(:unsafe_key), do: "the gateway key must be a 0600 file owned by this user"
  def describe(:invalid_key), do: "the gateway key is not an unencrypted EC or RSA key"
  def describe(:key_mismatch), do: "the gateway key does not belong to the certificate"

  def describe(:certificate_not_current),
    do: "the gateway certificate is expired or not yet valid"

  def describe(:identity_mismatch),
    do: "the gateway certificate does not name the advertised host"

  def describe(:invalid_owner), do: "the server owner could not be determined"
  def describe(:invalid_state_dir), do: "the state directory is not an absolute path"
  def describe(:unwritable), do: "server/endpoint.json could not be written"
  def describe(other), do: "unexpected gateway failure: #{inspect(other)}"
end
