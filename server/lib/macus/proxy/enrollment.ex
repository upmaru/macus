defmodule Macus.Proxy.Enrollment do
  @moduledoc """
  Expiring single-use native certificate enrollment tokens for the gateway.

  An untrusted standard Incus client enrolls with `incus remote add NAME
  TOKEN`, which sends `POST /1.0/certificates` with `trust_token` set to a
  native certificate add token (`api.CertificateAddToken`): base64 of
  `{"client_name", "fingerprint", "addresses", "secret", "expires_at"}`,
  where the fingerprint is the gateway certificate's and the client checks
  it before sending the token. Only the owner issues tokens, with `macus
  server trust token issue`; the token itself exists only in the file that
  command creates.

  Two owner-private files in the gateway directory hold the state, each
  with a single writer:

    * `trust-tokens.json`, written only by the owner's `macus` command:
      `{"schema_version": 1, "tokens": [record, ...]}` with records
      `%{"id", "verifier", "name", "created_at", "expires_at",
      "revoked_at"}`, optionally with `"client_fingerprint"`. The verifier
      is the lowercase hex SHA-256 of the token's secret; the secret is
      never stored. Every token expires.
    * `trust-token-redemptions.json`, written only by this process:
      `{"schema_version": 1, "redemptions": [%{"id", "redeemed_at",
      "fingerprint"}, ...]}`, recording which tokens are consumed and the
      certificate that presented each one.

  Redemption is serialized here and follows the native order: the token
  is consumed (the redemption written durably) before anything else, so a
  consumed token never enrolls again even after a failure, and an expired
  token is consumed and refused. Only then is the presented TLS peer
  certificate, whose private key the TLS handshake proved, added to gateway
  trust (`Macus.Proxy.Trust`) as an unrestricted client named by the token.
  Nothing from the request other than the token and the peer certificate is
  used, and nothing reaches the guest.

  A token whose record carries `client_fingerprint` (issued by `macus
  client setup`, which must pass it on the `incus remote add` command line)
  is bound to that certificate: any other peer certificate is refused with
  403 before the token is consumed, so a token seen by someone else neither
  enrolls them nor spends the owner's token. Redeeming a bound token for a
  certificate that is already trusted succeeds without adding a duplicate,
  because the owner explicitly issued it for that certificate. A store that is unsafe, oversized or
  malformed enrolls nothing and is never rewritten.
  """

  use GenServer

  alias Macus.{Configuration, PrivatePath}
  alias Macus.Auth.Token
  alias Macus.Proxy.Trust

  @tokens_file "trust-tokens.json"
  @redemptions_file "trust-token-redemptions.json"
  @max_bytes 1_048_576
  @max_tokens 1_024
  @max_token_bytes 8_192
  @id ~r/\A[0-9a-f]{16}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: {:ok, nil}

  @doc "The token store path for the selected state."
  @spec tokens_path(Configuration.t()) :: String.t()
  def tokens_path(%Configuration{} = state),
    do: Path.join(Configuration.gateway_dir(state), @tokens_file)

  @doc "The redemption record path for the selected state."
  @spec redemptions_path(Configuration.t()) :: String.t()
  def redemptions_path(%Configuration{} = state),
    do: Path.join(Configuration.gateway_dir(state), @redemptions_file)

  @doc """
  Decodes a native certificate add token as the native server does: strict
  base64 of a JSON object with a non-empty client name, gateway
  fingerprint, address list and secret.
  """
  @spec decode(term()) :: {:ok, map()} | :error
  def decode(token) when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with {:ok, json} <- Base.decode64(token),
         {:ok,
          %{
            "client_name" => name,
            "fingerprint" => fingerprint,
            "addresses" => [_ | _] = addresses,
            "secret" => secret
          }} <- Jason.decode(json),
         true <- Enum.all?([name, fingerprint, secret], &(is_binary(&1) and &1 != "")) do
      {:ok, %{client_name: name, fingerprint: fingerprint, addresses: addresses, secret: secret}}
    else
      _ -> :error
    end
  end

  def decode(_token), do: :error

  @doc """
  Redeems `secret` for the DER peer certificate `der` at `now`. Returns
  `{:ok, fingerprint}` once the certificate is trusted, or `{:error,
  status}`: 403 for an unknown, revoked, consumed or expired token, 409 when
  the certificate is already trusted (the token is still consumed) and 503
  when a store is unusable.
  """
  @spec redeem(Trust.store(), String.t(), binary(), DateTime.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, 403 | 409 | 503}
  def redeem(store, secret, der, now, server \\ __MODULE__),
    do: GenServer.call(server, {:redeem, store, secret, der, now})

  @impl true
  def handle_call({:redeem, store, secret, der, now}, _from, state) do
    {:reply, redeem_now(store, secret, der, now), state}
  end

  defp redeem_now(store, secret, der, now) do
    with {:ok, tokens} <- tokens(store),
         {:ok, redemptions} <- redemptions(store),
         {:ok, record} <- match(tokens, secret),
         :ok <- unconsumed(redemptions, record),
         :ok <- bound(record, der),
         :ok <- consume(store, tokens, redemptions, record, der, now),
         :ok <- current(record, now) do
      enroll(store, record, der, now)
    end
  end

  # Reading

  @doc """
  Reads the issued tokens. A missing gateway directory or store holds no
  tokens; anything unsafe or malformed is `{:error, 503}`.
  """
  @spec tokens(Trust.store()) :: {:ok, [map()]} | {:error, 503}
  def tokens(%{state: state, uid: uid}) do
    read(tokens_path(state), uid, "tokens", &token?/1)
  end

  @doc "Reads the redemption records, as `tokens/1` does."
  @spec redemptions(Trust.store()) :: {:ok, [map()]} | {:error, 503}
  def redemptions(%{state: state, uid: uid}) do
    read(redemptions_path(state), uid, "redemptions", &redemption?/1)
  end

  defp read(path, uid, key, valid?) do
    with :ok <- PrivatePath.private_dir(Path.dirname(path), uid),
         :ok <- PrivatePath.private_entry(path, uid, :regular),
         {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} when byte_size(bytes) <= @max_bytes <- File.read(path),
         {:ok, %{"schema_version" => 1, ^key => entries}} when is_list(entries) <-
           Jason.decode(bytes),
         true <- length(entries) <= @max_tokens,
         true <- Enum.all?(entries, valid?),
         ids = Enum.map(entries, & &1["id"]),
         true <- length(Enum.uniq(ids)) == length(ids) do
      {:ok, entries}
    else
      {:error, :enoent} -> {:ok, []}
      _ -> {:error, 503}
    end
  end

  # Every stored verifier is compared, so the match does not depend on
  # where a secret differs.
  defp match(tokens, secret) when is_binary(secret) do
    verifier = Token.verifier(secret)

    tokens
    |> Enum.filter(&Plug.Crypto.secure_compare(verifier, &1["verifier"]))
    |> case do
      [%{"revoked_at" => nil} = record] -> {:ok, record}
      _ -> {:error, 403}
    end
  end

  defp match(_tokens, _secret), do: {:error, 403}

  defp unconsumed(redemptions, %{"id" => id}) do
    if Enum.any?(redemptions, &(&1["id"] == id)), do: {:error, 403}, else: :ok
  end

  # A bound token is refused, unconsumed, for any other certificate.
  defp bound(%{"client_fingerprint" => fingerprint}, der) when is_binary(fingerprint) do
    if Plug.Crypto.secure_compare(Trust.fingerprint(der), fingerprint),
      do: :ok,
      else: {:error, 403}
  end

  defp bound(_record, _der), do: :ok

  defp current(%{"expires_at" => expires}, now) do
    with {:ok, at, 0} <- DateTime.from_iso8601(expires),
         :gt <- DateTime.compare(at, now) do
      :ok
    else
      _ -> {:error, 403}
    end
  end

  # Writing

  # Records for tokens no longer issued are dropped, so the file stays
  # bounded by the token store.
  defp consume(%{state: state} = store, tokens, redemptions, record, der, now) do
    issued = MapSet.new(tokens, & &1["id"])

    redemption = %{
      "id" => record["id"],
      "redeemed_at" => now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "fingerprint" => Trust.fingerprint(der)
    }

    document = %{
      "schema_version" => 1,
      "redemptions" => Enum.filter(redemptions, &MapSet.member?(issued, &1["id"])) ++ [redemption]
    }

    with :ok <- PrivatePath.private_dir(Configuration.gateway_dir(state), store.uid),
         {:ok, bytes} <- Jason.encode(document),
         true <- byte_size(bytes) < @max_bytes,
         :ok <- PrivatePath.replace(redemptions_path(state), [bytes, "\n"]) do
      :ok
    else
      _ -> {:error, 503}
    end
  end

  defp enroll(store, record, der, now) do
    entry = Trust.entry(der, record["name"], "", now)
    bound? = Map.has_key?(record, "client_fingerprint")

    Trust.update(store, fn entries ->
      cond do
        not Enum.any?(entries, &(&1["fingerprint"] == entry["fingerprint"])) ->
          {:ok, entries ++ [entry], entry["fingerprint"]}

        bound? ->
          {:noop, entry["fingerprint"]}

        true ->
          {:error, 409}
      end
    end)
    |> case do
      {:ok, fingerprint} -> {:ok, fingerprint}
      {:error, 409} -> {:error, 409}
      {:error, _reason} -> {:error, 503}
    end
  end

  # Validation

  defp token?(
         %{
           "id" => id,
           "verifier" => verifier,
           "name" => name,
           "created_at" => created_at,
           "expires_at" => expires_at,
           "revoked_at" => revoked_at
         } = record
       ) do
    is_binary(id) and Regex.match?(@id, id) and is_binary(verifier) and
      Regex.match?(@hex64, verifier) and Token.principal?(name) and timestamp?(created_at) and
      timestamp?(expires_at) and (is_nil(revoked_at) or timestamp?(revoked_at)) and
      Map.get(record, "type", "client") == "client" and
      Map.get(record, "restricted", false) == false and Map.get(record, "projects", []) == [] and
      fingerprint?(Map.get(record, "client_fingerprint", :unbound))
  end

  defp token?(_record), do: false

  defp redemption?(%{"id" => id, "redeemed_at" => redeemed_at, "fingerprint" => fingerprint}) do
    is_binary(id) and Regex.match?(@id, id) and timestamp?(redeemed_at) and
      is_binary(fingerprint) and Regex.match?(@hex64, fingerprint)
  end

  defp redemption?(_record), do: false

  defp fingerprint?(:unbound), do: true
  defp fingerprint?(value), do: is_binary(value) and Regex.match?(@hex64, value)

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false
end
