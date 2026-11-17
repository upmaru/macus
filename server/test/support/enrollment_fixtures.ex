defmodule Macus.TestSupport.EnrollmentFixtures do
  @moduledoc false
  # Issues enrollment tokens in the exact shape `macus server trust token
  # issue` writes: the stored record holds the verifier, the native token the
  # secret (Tests/MacusTests/TrustTokenTests.swift checks the Swift side).

  alias Macus.Proxy.{Enrollment, Trust}

  def issue!(store, name, gateway_der, addresses, opts \\ []) do
    secret = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires = Keyword.get(opts, :expires_at, DateTime.add(now, 3_600))

    record =
      Map.merge(
        %{
          "id" => id,
          "verifier" => Macus.Auth.Token.verifier(secret),
          "name" => name,
          "created_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(expires),
          "revoked_at" => nil
        },
        Keyword.get(opts, :fields, %{})
      )

    path = Enrollment.tokens_path(store.state)

    records =
      case File.read(path) do
        {:ok, bytes} -> Jason.decode!(bytes)["tokens"]
        _ -> []
      end

    File.write!(path, Jason.encode!(%{"schema_version" => 1, "tokens" => records ++ [record]}))
    File.chmod!(path, 0o600)

    token =
      Base.encode64(
        Jason.encode!(%{
          "client_name" => name,
          "fingerprint" => Trust.fingerprint(gateway_der),
          "addresses" => addresses,
          "secret" => secret,
          "expires_at" => DateTime.to_iso8601(expires)
        })
      )

    %{id: id, token: token, secret: secret}
  end
end
