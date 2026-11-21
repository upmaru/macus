defmodule Macus.Auth.Bearer do
  @moduledoc """
  Verifies Macus bearer credentials against the owner-private token store,
  `<state-dir>/server/bearer-tokens.json`:

      {"schema_version": 1, "tokens": [record, ...]}

  with records as described in `Macus.Auth.Token`. The gateway directory
  must be owner-private (0700, safe ancestry) and the file a 0600 regular
  file owned by the configured owner; neither is ever created here. The
  store is read on each verification, so a revoked or removed record stops
  new requests at once. It is bounded (1 MiB, 4096 records), and a store
  that is missing, unsafe, oversized or malformed in any record verifies
  nothing.

  A token verifies when its record exists, its secret matches the verifier
  (constant-time), it is neither revoked nor expired, and its scopes are
  all Macus scopes. The result is the identity `Macus.MCP.Authorization`
  turns into a decision; the owner key is `Macus.Auth.owner_key/1` of the
  configured owner.

  Configuration: the running gateway's state and owner when serving, else
  `config :macus, :state_dir` and `config :macus, Macus.Auth, owner_uid:
  uid` (`Macus.Auth.owner/0`).
  """

  alias Macus.{Auth, Configuration, PrivatePath}
  alias Macus.Auth.Token

  @file_name "bearer-tokens.json"
  @max_bytes 1_048_576
  @max_tokens 4_096
  # Compared when no record matches, so a missing ID costs the same.
  @absent_verifier String.duplicate("0", 64)

  @doc "The token store path for the selected state."
  @spec path(Configuration.t()) :: String.t()
  def path(%Configuration{} = state), do: Path.join(Configuration.gateway_dir(state), @file_name)

  @doc """
  Verifies `token`. Returns `{:ok, %{principal, owner_key, scopes,
  expires_at, claims, credential}}` or `{:error, :invalid_token}`; the
  reason never says which check failed. `credential` is the
  `Macus.Auth.Streams` key that keeps the request's streams tied to this
  record.
  """
  @spec verify(term()) :: {:ok, map()} | {:error, :invalid_token}
  def verify(token) do
    with {:ok, id, secret} <- Token.parse(token),
         {:ok, state, uid} <- config(),
         {:ok, records} <- load(path(state), uid),
         {:ok, record} <- match(records, id, secret),
         {:ok, expires_at} <- current(record, DateTime.utc_now()),
         true <- Token.scopes?(record["scopes"]) do
      {:ok,
       %{
         principal: record["principal"],
         owner_key: Auth.owner_key(uid),
         scopes: record["scopes"],
         expires_at: expires_at,
         claims: %{"token_id" => id},
         credential: {:bearer, id, record["verifier"], record["scopes"]}
       }}
    else
      _ -> {:error, :invalid_token}
    end
  end

  @doc """
  Reads and validates the store at `path` for owner `uid`. Returns the
  records keyed by ID, or `{:error, reason}`.
  """
  @spec load(String.t(), non_neg_integer()) :: {:ok, %{String.t() => map()}} | {:error, atom()}
  def load(path, uid) do
    with :ok <- PrivatePath.private_dir(Path.dirname(path), uid),
         :ok <- PrivatePath.private_entry(path, uid, :regular),
         {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, bytes} when byte_size(bytes) <= @max_bytes <- File.read(path),
         {:ok, %{"schema_version" => 1, "tokens" => tokens}} when is_list(tokens) <-
           Jason.decode(bytes),
         true <- length(tokens) <= @max_tokens,
         true <- Enum.all?(tokens, &record?/1),
         records = Map.new(tokens, &{&1["id"], &1}),
         true <- map_size(records) == length(tokens) do
      {:ok, records}
    else
      {:error, :enoent} -> {:error, :enoent}
      {:error, :unsafe} -> {:error, :unsafe}
      _ -> {:error, :invalid_store}
    end
  end

  defp match(records, id, secret) do
    record = Map.get(records, id)
    expected = if record, do: record["verifier"], else: @absent_verifier

    if Plug.Crypto.secure_compare(Token.verifier(secret), expected) and record,
      do: {:ok, record},
      else: :error
  end

  @doc "Whether a stored record is unrevoked and unexpired at `now`."
  @spec current?(map(), DateTime.t()) :: boolean()
  def current?(record, now), do: match?({:ok, _}, current(record, now))

  defp current(%{"revoked_at" => nil, "expires_at" => nil}, _now), do: {:ok, nil}

  defp current(%{"revoked_at" => nil, "expires_at" => expires}, now) do
    with {:ok, at, 0} <- DateTime.from_iso8601(expires),
         :gt <- DateTime.compare(at, now) do
      {:ok, at}
    else
      _ -> :error
    end
  end

  defp current(_record, _now), do: :error

  defp record?(%{"id" => id, "verifier" => verifier, "principal" => principal} = record) do
    is_binary(id) and Regex.match?(~r/\A[0-9a-f]{16}\z/, id) and is_binary(verifier) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, verifier) and Token.principal?(principal) and
      is_list(record["scopes"]) and Enum.all?(record["scopes"], &is_binary/1) and
      timestamp?(record["created_at"]) and nullable_timestamp?(record["expires_at"]) and
      nullable_timestamp?(record["revoked_at"])
  end

  defp record?(_record), do: false

  defp nullable_timestamp?(nil), do: true
  defp nullable_timestamp?(value), do: timestamp?(value)

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_value), do: false

  @doc false
  def config, do: Auth.owner()
end
