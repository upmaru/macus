defmodule Macus.Proxy.Trust do
  @moduledoc """
  The gateway's own client-certificate trust store,
  `<state-dir>/server/trusted-certificates.json`:

      {"schema_version": 1, "certificates": [entry, ...]}

  An entry is `%{"fingerprint", "name", "type", "certificate",
  "description", "created_at"}`: the lowercase hex SHA-256 of the DER
  certificate, a name, the type `"client"`, the PEM certificate, a
  description and an ISO 8601 UTC creation time. Every enrolled certificate
  is an owner-admin client with full native access; restricted and project
  scoped certificates are never stored.

  This is gateway trust only. The guest's Incus trust store is never read
  or written here, and nothing the guest trusts grants gateway access.

  The gateway directory must already be owner-private (`Macus.PrivatePath`)
  and the store a 0600 regular file owned by the owner. Reads happen on
  every request, so a removed certificate stops new requests at once.
  Changes are serialized through this process and replace the file
  atomically, keeping every other entry and unknown field. A store that is
  unsafe, oversized or malformed in any entry trusts nothing and is never
  rewritten.
  """

  use GenServer

  alias Macus.{Configuration, PrivatePath}

  @file_name "trusted-certificates.json"
  @max_bytes 1_048_576
  @max_entries 1_024
  @fingerprint ~r/\A[0-9a-f]{64}\z/

  @type store :: %{state: Configuration.t(), uid: non_neg_integer()}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: {:ok, nil}

  @doc "The store path for the selected state."
  @spec path(Configuration.t()) :: String.t()
  def path(%Configuration{} = state), do: Path.join(Configuration.gateway_dir(state), @file_name)

  @doc "The SHA-256 fingerprint of a DER certificate."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  # Reading

  @doc """
  Reads the store. A missing file is an empty store; anything unsafe or
  malformed is `{:error, reason}`.
  """
  @spec load(store()) :: {:ok, map()} | {:error, atom()}
  def load(%{state: state, uid: uid}) do
    path = path(state)

    with :ok <- PrivatePath.private_dir(Path.dirname(path), uid) do
      case PrivatePath.private_entry(path, uid, :regular) do
        :ok -> read(path)
        {:error, :enoent} -> {:ok, %{"schema_version" => 1, "certificates" => []}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read(path) do
    with {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} when byte_size(bytes) <= @max_bytes <- File.read(path),
         {:ok, %{"schema_version" => 1, "certificates" => entries} = document}
         when is_list(entries) <- Jason.decode(bytes),
         true <- length(entries) <= @max_entries,
         true <- Enum.all?(entries, &entry?/1),
         fingerprints = Enum.map(entries, & &1["fingerprint"]),
         true <- length(Enum.uniq(fingerprints)) == length(fingerprints) do
      {:ok, document}
    else
      _ -> {:error, :invalid_store}
    end
  end

  @doc "All entries, in store order."
  @spec entries(store()) :: {:ok, [map()]} | {:error, atom()}
  def entries(store) do
    with {:ok, document} <- load(store), do: {:ok, document["certificates"]}
  end

  @doc """
  Finds the entry trusting this DER certificate, valid at `now`: the stored
  PEM must be exactly this certificate and within its validity period.
  """
  @spec lookup(store(), binary(), DateTime.t()) :: {:ok, map()} | :error
  def lookup(store, der, now) when is_binary(der) do
    fingerprint = fingerprint(der)

    with {:ok, entries} <- entries(store),
         %{} = entry <- Enum.find(entries, &(&1["fingerprint"] == fingerprint)),
         {:ok, ^der} <- der(entry["certificate"]),
         true <- valid_at?(der, now) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  def lookup(_store, _der, _now), do: :error

  # Changing

  @doc """
  Applies `change` to the current entries under the store's lock and writes
  the result. `change` receives the entries and returns `{:ok, entries,
  reply}` to write, `{:noop, reply}` or `{:error, status}`.
  """
  @spec update(store(), ([map()] -> {:ok, [map()], term()} | {:noop, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def update(store, change, server \\ __MODULE__),
    do: GenServer.call(server, {:update, store, change})

  @impl true
  def handle_call({:update, store, change}, _from, state) do
    reply =
      with {:ok, document} <- load(store) do
        case change.(document["certificates"]) do
          {:ok, entries, reply} when is_list(entries) ->
            with :ok <- write(store, Map.put(document, "certificates", entries)),
                 do: {:ok, reply}

          {:noop, reply} ->
            {:ok, reply}

          {:error, reason} ->
            {:error, reason}
        end
      end

    {:reply, reply, state}
  end

  defp write(%{state: state} = store, document) do
    with true <- length(document["certificates"]) <= @max_entries,
         {:ok, bytes} <- Jason.encode(document),
         true <- byte_size(bytes) < @max_bytes,
         :ok <- PrivatePath.private_dir(Path.dirname(path(state)), store.uid) do
      replace(path(state), bytes <> "\n")
    else
      _ -> {:error, :unwritable}
    end
  end

  defp replace(path, bytes) do
    temporary =
      Path.join(
        Path.dirname(path),
        ".trusted-certificates.#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.tmp"
      )

    result =
      with {:ok, device} <- :file.open(temporary, [:write, :exclusive, :binary, :raw]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- :file.write(device, bytes),
           :ok <- :file.sync(device),
           :ok <- :file.close(device) do
        File.rename(temporary, path)
      end

    case result do
      :ok ->
        :ok

      _ ->
        File.rm(temporary)
        {:error, :unwritable}
    end
  end

  # Entries

  @doc "Builds a new entry for a DER certificate."
  @spec entry(binary(), String.t(), String.t(), DateTime.t()) :: map()
  def entry(der, name, description, now) do
    %{
      "fingerprint" => fingerprint(der),
      "name" => name,
      "type" => "client",
      "certificate" => pem(der),
      "description" => description,
      "created_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  @doc "PEM encoding of a DER certificate."
  def pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  @doc "The DER certificate in a single-certificate PEM."
  @spec der(term()) :: {:ok, binary()} | :error
  def der(pem) when is_binary(pem) and byte_size(pem) <= 65_536 do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] -> if certificate?(der), do: {:ok, der}, else: :error
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def der(_pem), do: :error

  @doc "Whether `der` parses as an X.509 certificate."
  def certificate?(der) do
    _ = :public_key.pkix_decode_cert(der, :otp)
    true
  rescue
    _ -> false
  end

  @doc "Whether `now` is within the certificate's validity period."
  @spec valid_at?(binary(), DateTime.t()) :: boolean()
  def valid_at?(der, now) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    {:Validity, not_before, not_after} = elem(tbs, 5)
    seconds = DateTime.to_unix(now) + 62_167_219_200

    :pubkey_cert.time_str_2_gregorian_sec(not_before) <= seconds and
      seconds <= :pubkey_cert.time_str_2_gregorian_sec(not_after)
  rescue
    _ -> false
  end

  @doc "The certificate's common name, or `nil`."
  def common_name(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)

    {:rdnSequence, rdns} = elem(tbs, 6)

    Enum.find_value(List.flatten(rdns), fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, value}} -> to_string(value)
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} when is_binary(value) -> value
      _ -> nil
    end)
  rescue
    _ -> nil
  end

  defp entry?(
         %{
           "fingerprint" => fingerprint,
           "name" => name,
           "type" => "client",
           "certificate" => certificate,
           "description" => description,
           "created_at" => created_at
         } = entry
       ) do
    is_binary(fingerprint) and Regex.match?(@fingerprint, fingerprint) and is_binary(name) and
      byte_size(name) <= 255 and is_binary(certificate) and byte_size(certificate) <= 65_536 and
      is_binary(description) and byte_size(description) <= 4_096 and is_binary(created_at) and
      match?({:ok, _, 0}, DateTime.from_iso8601(created_at)) and
      Map.get(entry, "restricted", false) == false and Map.get(entry, "projects", []) == []
  end

  defp entry?(_entry), do: false
end
