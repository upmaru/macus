defmodule Macus.Gateway.Certificate do
  @moduledoc """
  The gateway's TLS identity: a certificate (optionally followed by its
  chain) and the matching private key.

  `generate/3` creates the default self-signed identity once, as Incus
  does: an ECDSA P-384 key and a ten-year certificate for `localhost`,
  `127.0.0.1` and `::1`, both written as new owner-private files. It never
  replaces an existing file.

  `load/4` accepts the default identity or an operator-supplied one. The
  key must be an unencrypted owner-private (0600) regular file; the
  certificate an owner's regular file nobody else can write; both below
  safe ancestors, never symbolic links. The key must belong to the leaf
  certificate (proved by a signature), the leaf must be within its
  validity period and must name the advertised host (`subjectAltName`
  DNS name or IP address). Nothing is changed.
  """

  require Record

  for {name, record} <- [
        tbs: :OTPTBSCertificate,
        spki: :OTPSubjectPublicKeyInfo,
        algorithm: :PublicKeyAlgorithm,
        validity: :Validity,
        extension: :Extension,
        ec_point: :ECPoint,
        basic_constraints: :BasicConstraints
      ] do
    Record.defrecordp(
      name,
      record,
      Record.extract(record, from_lib: "public_key/include/public_key.hrl")
    )
  end

  alias Macus.PrivatePath
  alias Macus.Proxy.Trust

  @max_bytes 65_536
  @max_chain 8
  @ecdsa_sha384 {1, 2, 840, 10_045, 4, 3, 3}
  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}

  @type t :: %{der: binary(), pem: String.t(), fingerprint: String.t()}

  @doc """
  Writes a new self-signed identity to `certfile` and `keyfile`. Both must
  be absent; on any failure the files this call created are removed.
  """
  @spec generate(String.t(), String.t(), DateTime.t()) :: :ok | {:error, :exists | :unwritable}
  def generate(certfile, keyfile, now) do
    key = :public_key.generate_key({:namedCurve, :secp384r1})
    der = :public_key.pkix_sign(self_signed(key, now), key)
    key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

    with :ok <- write_new(keyfile, key_pem) do
      case write_new(certfile, Trust.pem(der)) do
        :ok ->
          :ok

        error ->
          File.rm(keyfile)
          error
      end
    end
  end

  defp self_signed({:ECPrivateKey, _version, _private, parameters, public, _attributes}, now) do
    name =
      {:rdnSequence,
       [
         [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Macus"}}],
         [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "macus gateway"}}]
       ]}

    tbs(
      version: :v3,
      serialNumber: :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned() |> Bitwise.bsr(1),
      signature: {:SignatureAlgorithm, @ecdsa_sha384, :asn1_NOVALUE},
      issuer: name,
      validity:
        validity(
          notBefore: time(DateTime.add(now, -60)),
          notAfter: time(DateTime.add(now, 3650 * 86_400))
        ),
      subject: name,
      subjectPublicKeyInfo:
        spki(
          algorithm: algorithm(algorithm: @ec_public_key, parameters: parameters),
          subjectPublicKey: ec_point(point: public)
        ),
      extensions: [
        extension(
          extnID: {2, 5, 29, 19},
          critical: true,
          extnValue: basic_constraints(cA: false, pathLenConstraint: :asn1_NOVALUE)
        ),
        extension(extnID: {2, 5, 29, 15}, critical: true, extnValue: [:digitalSignature]),
        extension(
          extnID: {2, 5, 29, 37},
          critical: false,
          extnValue: [{1, 3, 6, 1, 5, 5, 7, 3, 1}]
        ),
        extension(
          extnID: {2, 5, 29, 17},
          critical: false,
          extnValue: [
            {:dNSName, ~c"localhost"},
            {:iPAddress, <<127, 0, 0, 1>>},
            {:iPAddress, <<1::128>>}
          ]
        )
      ]
    )
  end

  # RFC 5280 section 4.1.2.5: UTCTime through 2049, GeneralizedTime after.
  # OpenSSL and LibreSSL reject a GeneralizedTime before 2050.
  defp time(%DateTime{year: year} = datetime) when year < 2050,
    do: {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp time(datetime),
    do: {:generalTime, datetime |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  defp write_new(path, bytes) do
    case :file.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, device} ->
        result =
          with :ok <- File.chmod(path, 0o600),
               :ok <- :file.write(device, bytes),
               :ok <- :file.sync(device) do
            :ok
          end

        :file.close(device)

        if result == :ok do
          :ok
        else
          File.rm(path)
          {:error, :unwritable}
        end

      {:error, :eexist} ->
        {:error, :exists}

      _ ->
        {:error, :unwritable}
    end
  end

  @doc """
  Loads and checks the identity for `host` (the advertised host name or
  IP literal) at `now`, with files owned by `uid`.
  """
  @spec load(
          %{certfile: String.t(), keyfile: String.t()},
          non_neg_integer(),
          String.t(),
          DateTime.t()
        ) ::
          {:ok, t()}
          | {:error,
             :unsafe_certificate
             | :invalid_certificate
             | :unsafe_key
             | :invalid_key
             | :key_mismatch
             | :certificate_not_current
             | :identity_mismatch}
  def load(%{certfile: certfile, keyfile: keyfile}, uid, host, now) do
    with {:ok, chain} <- read_certificate(certfile, uid),
         {:ok, key} <- read_key(keyfile, uid),
         [leaf | _] = chain,
         :ok <- matches(leaf, key),
         true <- Trust.valid_at?(leaf, now) || {:error, :certificate_not_current},
         true <- names?(leaf, host) || {:error, :identity_mismatch} do
      {:ok, %{der: leaf, pem: Trust.pem(leaf), fingerprint: Trust.fingerprint(leaf)}}
    end
  end

  defp read_certificate(path, uid) do
    with :ok <- public_file(path, uid),
         {:ok, pem} <- File.read(PrivatePath.system_alias(path)),
         entries when entries != [] and length(entries) <= @max_chain <- safe_decode(pem),
         true <- Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1)),
         ders = Enum.map(entries, &elem(&1, 1)),
         true <- Enum.all?(ders, &Trust.certificate?/1) do
      {:ok, ders}
    else
      {:error, :unsafe} -> {:error, :unsafe_certificate}
      _ -> {:error, :invalid_certificate}
    end
  end

  defp read_key(path, uid) do
    with :ok <- PrivatePath.private_entry(path, uid, :regular),
         :ok <- PrivatePath.safe_ancestors(Path.dirname(PrivatePath.system_alias(path)), uid),
         {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, pem} <- File.read(PrivatePath.system_alias(path)),
         [{type, _der, :not_encrypted} = entry]
         when type in [:ECPrivateKey, :RSAPrivateKey, :PrivateKeyInfo] <- safe_decode(pem),
         {:ok, key} <- decode_key(entry) do
      {:ok, key}
    else
      {:error, reason} when reason in [:unsafe, :enoent] -> {:error, :unsafe_key}
      _ -> {:error, :invalid_key}
    end
  end

  # The certificate is public, but it must be the owner's regular file,
  # writable by nobody else, below safe ancestors.
  defp public_file(path, uid) do
    real = PrivatePath.system_alias(path)

    case File.lstat(real) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode, size: size}}
      when size <= @max_bytes ->
        if Bitwise.band(mode, 0o022) == 0,
          do: PrivatePath.safe_ancestors(Path.dirname(real), uid),
          else: {:error, :unsafe}

      _ ->
        {:error, :unsafe}
    end
  end

  defp safe_decode(pem) do
    :public_key.pem_decode(pem)
  rescue
    _ -> :error
  end

  defp decode_key(entry) do
    case :public_key.pem_entry_decode(entry) do
      {:ECPrivateKey, _, _, _, _, _} = key -> {:ok, key}
      {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key -> {:ok, key}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The key belongs to the leaf when a signature it makes verifies under
  # the leaf's public key.
  defp matches(leaf, key) do
    message = :crypto.strong_rand_bytes(32)

    with {:ok, public} <- public_key(leaf),
         signature = :public_key.sign(message, :sha256, key),
         true <- :public_key.verify(message, :sha256, signature, public) do
      :ok
    else
      _ -> {:error, :key_mismatch}
    end
  rescue
    _ -> {:error, :key_mismatch}
  end

  defp public_key(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)

    case tbs(tbs, :subjectPublicKeyInfo) do
      spki(
        algorithm: algorithm(algorithm: @ec_public_key, parameters: parameters),
        subjectPublicKey: point
      ) ->
        {:ok, {point, parameters}}

      spki(algorithm: algorithm(algorithm: @rsa_encryption), subjectPublicKey: rsa) ->
        {:ok, rsa}

      _ ->
        :error
    end
  end

  defp names?(der, host) do
    reference =
      case :inet.parse_strict_address(String.to_charlist(host)) do
        {:ok, ip} -> [ip: ip]
        _ -> [dns_id: String.to_charlist(host)]
      end

    :public_key.pkix_verify_hostname(der, reference)
  rescue
    _ -> false
  end
end
