defmodule Macus.Auth.Token do
  @moduledoc """
  Macus bearer credentials: their wire format, scopes and stored records.

  A token is `macus.<id>.<secret>`: a 16-character lowercase hex `id` and a
  43-character base64url `secret` (32 random bytes). Only a record is
  stored, keyed by `id` and holding the SHA-256 of the secret as its
  `verifier`, never the secret itself. The secret is high-entropy, so a fast
  hash is a sufficient verifier.

  A record is `%{"id", "verifier", "principal", "scopes", "created_at",
  "expires_at", "revoked_at"}` (timestamps are ISO 8601 UTC or `nil`).
  Scopes are limited to `scopes/0`. The `incus.native.*` scopes reach the
  native client operations and are granted only when named explicitly; no
  other scope implies them.

  `new/3` is pure. Writing records to the private store is the owner's
  administration command (task 3.4).
  """

  @scopes ~w(incus.read incus.write incus.exec incus.delete runtime.read runtime.write runtime.delete
             incus.native.read incus.native.write incus.native.delete incus.native.admin)
  @token ~r/\Amacus\.([0-9a-f]{16})\.([A-Za-z0-9_-]{43})\z/
  @principal ~r/\A[A-Za-z0-9][A-Za-z0-9._@-]{0,127}\z/

  @doc "The scopes a Macus bearer credential may carry."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc """
  Creates a token and its record for `principal` with `scopes`. Options:
  `:expires_at` (a future `DateTime`, default none) and `:now`.
  Refuses unknown, duplicate or empty scopes.
  """
  @spec new(String.t(), [String.t()], keyword()) ::
          {:ok, String.t(), map()}
          | {:error, :invalid_principal | :invalid_scopes | :invalid_expiry}
  def new(principal, scopes, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    expires_at = Keyword.get(opts, :expires_at)

    cond do
      not principal?(principal) ->
        {:error, :invalid_principal}

      not scopes?(scopes) ->
        {:error, :invalid_scopes}

      not (is_nil(expires_at) or
               (match?(%DateTime{}, expires_at) and DateTime.compare(expires_at, now) == :gt)) ->
        {:error, :invalid_expiry}

      true ->
        id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        record = %{
          "id" => id,
          "verifier" => verifier(secret),
          "principal" => principal,
          "scopes" => scopes,
          "created_at" => iso(now),
          "expires_at" => expires_at && iso(expires_at),
          "revoked_at" => nil
        }

        {:ok, "macus.#{id}.#{secret}", record}
    end
  end

  @doc "Splits a token into `{id, secret}`, or `:error` when it is not a Macus token."
  @spec parse(term()) :: {:ok, String.t(), String.t()} | :error
  def parse(token) when is_binary(token) do
    case Regex.run(@token, token, capture: :all_but_first) do
      [id, secret] -> {:ok, id, secret}
      nil -> :error
    end
  end

  def parse(_token), do: :error

  @doc "The stored verifier for a secret: lowercase hex SHA-256."
  @spec verifier(String.t()) :: String.t()
  def verifier(secret), do: Base.encode16(:crypto.hash(:sha256, secret), case: :lower)

  @doc false
  def principal?(principal), do: is_binary(principal) and Regex.match?(@principal, principal)

  @doc false
  def scopes?(scopes) do
    is_list(scopes) and scopes != [] and Enum.all?(scopes, &(&1 in @scopes)) and
      length(scopes) == length(Enum.uniq(scopes))
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
