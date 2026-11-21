defmodule Macus.Gateway.Config do
  @moduledoc """
  The owner's gateway listener configuration, `<state-dir>/server/gateway.json`:

      {
        "schema_version": 1,
        "bind_address": "192.168.1.20",
        "port": 8443,
        "advertised_url": "https://macus.example.net:8443",
        "certificate_file": "/Users/me/certs/macus.example.net.pem",
        "key_file": "/Users/me/certs/macus.example.net.key"
      }

  Every field but `schema_version` is optional, and without the file the
  gateway listens on loopback only: `127.0.0.1:8443`, advertised as
  `https://127.0.0.1:8443`, with the generated default identity
  `<state-dir>/server/gateway.crt` and `gateway.key`.

  - `bind_address` is an IP literal. The unspecified addresses
    (`0.0.0.0`, `::`) are refused: the gateway never binds every interface.
  - A non-loopback `bind_address` needs an explicit `advertised_url` whose
    host is not a loopback name; nothing is inferred from interfaces.
  - `advertised_url` is `https://HOST[:PORT]` with no path, query or user
    information. It is what clients connect to and what the gateway
    certificate must name; the default identity names only loopback, so a
    LAN or remote identity needs `certificate_file` and `key_file`, which
    are absolute paths given together.

  The file must be an owner-private (0600) regular file of at most 64 KiB
  in the private gateway directory. Unknown fields are refused. Loading
  creates and changes nothing.
  """

  alias Macus.{Configuration, PrivatePath}

  @file_name "gateway.json"
  @max_bytes 65_536
  @fields ~w(schema_version bind_address port advertised_url certificate_file key_file)
  @default_bind {127, 0, 0, 1}
  @default_port 8443

  @enforce_keys [:bind_ip, :port, :url, :host, :address, :certfile, :keyfile, :default_identity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bind_ip: :inet.ip_address(),
          port: :inet.port_number(),
          url: String.t(),
          host: String.t(),
          address: String.t(),
          certfile: String.t(),
          keyfile: String.t(),
          default_identity: boolean()
        }

  @type error ::
          :unsafe_configuration
          | {:invalid_configuration, String.t()}
          | :wildcard_bind
          | :advertised_url_required

  @spec path(Configuration.t()) :: String.t()
  def path(%Configuration{} = state), do: Path.join(Configuration.gateway_dir(state), @file_name)

  @doc """
  Loads the configuration for `state`, whose gateway directory the caller
  has checked, with the file owned by `uid`.
  """
  @spec load(Configuration.t(), non_neg_integer()) :: {:ok, t()} | {:error, error()}
  def load(%Configuration{} = state, uid) do
    case read(path(state), uid) do
      {:ok, fields} -> build(state, fields)
      {:error, :enoent} -> build(state, %{"schema_version" => 1})
      {:error, _} = error -> error
    end
  end

  defp read(path, uid) do
    with :ok <- PrivatePath.private_entry(path, uid, :regular),
         {:ok, %File.Stat{size: size}} when size <= @max_bytes <-
           File.lstat(PrivatePath.system_alias(path)),
         {:ok, bytes} <- File.read(PrivatePath.system_alias(path)),
         {:ok, %{} = fields} <- Jason.decode(bytes) do
      {:ok, fields}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, :unsafe} -> {:error, :unsafe_configuration}
      {:ok, %File.Stat{}} -> {:error, :unsafe_configuration}
      _ -> {:error, {:invalid_configuration, "gateway.json"}}
    end
  end

  @doc "Builds a configuration from decoded `gateway.json` fields."
  @spec build(Configuration.t(), map()) :: {:ok, t()} | {:error, error()}
  def build(%Configuration{} = state, fields) when is_map(fields) do
    with :ok <- known(fields),
         :ok <- schema(fields),
         {:ok, ip} <- bind(Map.get(fields, "bind_address")),
         {:ok, port} <- port(Map.get(fields, "port", @default_port)),
         {:ok, {url, host, advertised_port}} <-
           advertised(Map.get(fields, "advertised_url"), ip, port),
         {:ok, {certfile, keyfile, default?}} <- identity_files(state, fields) do
      {:ok,
       %__MODULE__{
         bind_ip: ip,
         port: port,
         url: url,
         host: host,
         address: authority(host, advertised_port),
         certfile: certfile,
         keyfile: keyfile,
         default_identity: default?
       }}
    end
  end

  defp known(fields) do
    case Map.keys(fields) -- @fields do
      [] -> :ok
      [field | _] -> {:error, {:invalid_configuration, field}}
    end
  end

  defp schema(%{"schema_version" => 1}), do: :ok
  defp schema(_fields), do: {:error, {:invalid_configuration, "schema_version"}}

  defp bind(nil), do: {:ok, @default_bind}

  defp bind(address) when is_binary(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} when ip in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}] -> {:error, :wildcard_bind}
      {:ok, ip} -> if usable?(ip), do: {:ok, ip}, else: invalid("bind_address")
      _ -> invalid("bind_address")
    end
  end

  defp bind(_address), do: invalid("bind_address")

  # Multicast and broadcast addresses cannot be listened on.
  defp usable?({a, _, _, _} = ip), do: a < 224 and ip != {255, 255, 255, 255}
  defp usable?({a, _, _, _, _, _, _, _}), do: a < 0xFF00

  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(_port), do: invalid("port")

  defp advertised(nil, ip, port) do
    if loopback?(ip),
      do: {:ok, {"https://" <> authority(ip_string(ip), port), ip_string(ip), port}},
      else: {:error, :advertised_url_required}
  end

  defp advertised(url, ip, _port) when is_binary(url) and byte_size(url) <= 2048 do
    uri = URI.parse(url)

    with true <- uri.scheme == "https" and uri.userinfo == nil and uri.path in [nil, ""],
         true <- uri.query == nil and uri.fragment == nil and is_integer(uri.port),
         true <- uri.port in 1..65_535 and host?(uri.host),
         true <- loopback?(ip) or not loopback_name?(uri.host) do
      {:ok, {"https://" <> authority(uri.host, uri.port), uri.host, uri.port}}
    else
      _ -> invalid("advertised_url")
    end
  end

  defp advertised(_url, _ip, _port), do: invalid("advertised_url")

  defp host?(host) when is_binary(host) and host != "" do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip not in [{0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 0}]

      _ ->
        byte_size(host) <= 253 and
          Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/, host)
    end
  end

  defp host?(_host), do: false

  defp loopback_name?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        loopback?(ip)

      _ ->
        String.downcase(host) == "localhost" or
          String.ends_with?(String.downcase(host), ".localhost")
    end
  end

  @doc false
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_ip), do: false

  @doc """
  The shared gateway identity scope for this listener: `:local` when it
  binds a loopback, private (RFC 1918, carrier-grade NAT, unique local) or
  link-local address, so its identity may advertise local addresses and
  names as native Incus does; `:public` otherwise.
  """
  @spec identity_scope(t()) :: :local | :public
  def identity_scope(%__MODULE__{bind_ip: ip}), do: if(local?(ip), do: :local, else: :public)

  defp local?(ip) when tuple_size(ip) == 4 do
    case ip do
      {127, _, _, _} -> true
      {10, _, _, _} -> true
      {172, b, _, _} -> b in 16..31
      {192, 168, _, _} -> true
      {100, b, _, _} -> b in 64..127
      {169, 254, _, _} -> true
      _ -> false
    end
  end

  defp local?({a, _, _, _, _, _, _, _} = ip),
    do: loopback?(ip) or a in 0xFC00..0xFDFF or a in 0xFE80..0xFEBF

  defp identity_files(state, fields) do
    case {Map.get(fields, "certificate_file"), Map.get(fields, "key_file")} do
      {nil, nil} ->
        dir = Configuration.gateway_dir(state)
        {:ok, {Path.join(dir, "gateway.crt"), Path.join(dir, "gateway.key"), true}}

      {certfile, keyfile} ->
        cond do
          not absolute?(certfile) -> invalid("certificate_file")
          not absolute?(keyfile) -> invalid("key_file")
          true -> {:ok, {certfile, keyfile, false}}
        end
    end
  end

  defp absolute?(path),
    do: is_binary(path) and Path.type(path) == :absolute and not String.contains?(path, <<0>>)

  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp authority(host, port) do
    if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  defp invalid(field), do: {:error, {:invalid_configuration, field}}
end
