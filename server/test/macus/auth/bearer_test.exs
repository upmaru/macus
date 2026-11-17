defmodule Macus.Auth.BearerTest do
  # The state directory and owner are application environment.
  use ExUnit.Case, async: false

  alias Macus.Auth
  alias Macus.Auth.{Bearer, Token}
  alias Macus.TestSupport.{AuthFixtures, DexFixtures}

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)
    %{state: state, uid: uid}
  end

  describe "Token" do
    test "new/3 issues a parseable token whose record holds only a verifier" do
      now = ~U[2026-11-17 10:00:00.123456Z]
      expires = DateTime.add(now, 3600)

      {:ok, token, record} =
        Token.new("owner", ["incus.read", "runtime.read"], now: now, expires_at: expires)

      assert {:ok, id, secret} = Token.parse(token)
      assert record["id"] == id
      assert record["verifier"] == Token.verifier(secret)
      refute inspect(record) =~ secret
      assert record["created_at"] == "2026-11-17T10:00:00Z"
      assert record["expires_at"] == "2026-11-17T11:00:00Z"
      assert record["revoked_at"] == nil
      assert Regex.match?(~r/\A[A-Za-z0-9\-._~+\/]+=*\z/, token)
    end

    test "new/3 refuses native, unknown, duplicate or empty scopes" do
      for scopes <- [
            ["incus.native.read"],
            ["incus.native.instances.write"],
            ["admin"],
            ["incus.read", "incus.read"],
            [],
            "incus.read"
          ] do
        assert Token.new("owner", scopes) == {:error, :invalid_scopes}, inspect(scopes)
      end
    end

    test "new/3 refuses a bad principal or a past expiry" do
      assert Token.new("", ["incus.read"]) == {:error, :invalid_principal}
      assert Token.new("a b", ["incus.read"]) == {:error, :invalid_principal}

      past = DateTime.add(DateTime.utc_now(), -1)
      assert Token.new("owner", ["incus.read"], expires_at: past) == {:error, :invalid_expiry}
      assert Token.new("owner", ["incus.read"], expires_at: "never") == {:error, :invalid_expiry}
    end

    test "parse/1 accepts only the Macus format" do
      {token, _record} = AuthFixtures.token!(["incus.read"])
      assert {:ok, _, _} = Token.parse(token)

      for bad <- [nil, "", "good-token", token <> "x", "MACUS" <> String.slice(token, 5..-1//1)] do
        assert Token.parse(bad) == :error, inspect(bad)
      end
    end

    test "verifiers and scopes match the Swift administration commands" do
      # The same vector is asserted by Tests/MacusTests/ServerAdministrationTests.swift.
      assert Token.verifier("secret") ==
               "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b"

      swift =
        File.read!(
          Path.expand("../../../../Sources/Macus/Gateway/BearerTokenStore.swift", __DIR__)
        )

      [scopes] = Regex.run(~r/static let scopes = \[(.*?)\]/s, swift, capture: :all_but_first)

      assert Regex.scan(~r/"([a-z.]+)"/, scopes, capture: :all_but_first) |> List.flatten() ==
               Token.scopes()
    end

    test "a store written by macus server token issue verifies", %{state: state} do
      secret = String.duplicate("A", 43)
      id = "e73c0aba13ed3243"
      path = Bearer.path(%Macus.Configuration{state_dir: state})

      # The exact shape the Swift command writes: sorted keys, explicit nulls, a newline.
      File.write!(
        path,
        ~s({"schema_version":1,"tokens":[{"created_at":"2026-11-17T10:04:01Z","expires_at":null,) <>
          ~s("id":"#{id}","principal":"ci@host","revoked_at":null,"scopes":["incus.read","incus.exec"],) <>
          ~s("verifier":"#{Token.verifier(secret)}"}]}\n)
      )

      File.chmod!(path, 0o600)

      assert {:ok, %{principal: "ci@host", scopes: ["incus.read", "incus.exec"]}} =
               Bearer.verify("macus.#{id}.#{secret}")
    end

    test "Macus scopes are distinct and never native" do
      assert Token.scopes() == Enum.uniq(Token.scopes())
      refute Enum.any?(Token.scopes(), &String.starts_with?(&1, "incus.native."))
    end
  end

  describe "verify/1" do
    test "a stored token verifies to the owner's identity", %{state: state, uid: uid} do
      expires = DateTime.add(DateTime.utc_now(), 3600)
      {token, record} = AuthFixtures.token!(["incus.read", "incus.exec"], expires_at: expires)
      {other, other_record} = AuthFixtures.token!(["runtime.write"], principal: "ci@host")
      AuthFixtures.store!(state, [record, other_record])

      assert {:ok, verified} = Bearer.verify(token)
      assert verified.principal == "owner"
      assert verified.owner_key == Auth.owner_key(uid)
      assert verified.scopes == ["incus.read", "incus.exec"]
      assert verified.expires_at == DateTime.truncate(expires, :second)
      assert verified.claims == %{"token_id" => record["id"]}

      assert {:ok, %{principal: "ci@host", scopes: ["runtime.write"], expires_at: nil}} =
               Bearer.verify(other)
    end

    test "unknown, wrong-secret and malformed tokens are refused", %{state: state} do
      {token, record} = AuthFixtures.token!(["incus.read"])
      {unknown, _} = AuthFixtures.token!(["incus.read"])
      AuthFixtures.store!(state, [record])
      {:ok, id, _secret} = Token.parse(token)
      {:ok, _, wrong_secret} = Token.parse(unknown)

      for bad <- [unknown, "macus.#{id}.#{wrong_secret}", "good-token", nil, 42] do
        assert Bearer.verify(bad) == {:error, :invalid_token}, inspect(bad)
      end
    end

    test "revoked or expired records are refused", %{state: state} do
      {revoked, revoked_record} = AuthFixtures.token!(["incus.read"])
      {expired, expired_record} = AuthFixtures.token!(["incus.read"])

      AuthFixtures.store!(state, [
        %{revoked_record | "revoked_at" => "2026-01-01T00:00:00Z"},
        %{expired_record | "expires_at" => "2020-01-01T00:00:00Z"}
      ])

      assert Bearer.verify(revoked) == {:error, :invalid_token}
      assert Bearer.verify(expired) == {:error, :invalid_token}
    end

    test "revocation applies to the next request", %{state: state} do
      {token, record} = AuthFixtures.token!(["incus.read"])
      AuthFixtures.store!(state, [record])
      assert {:ok, _} = Bearer.verify(token)

      AuthFixtures.store!(state, [%{record | "revoked_at" => "2026-01-01T00:00:00Z"}])
      assert Bearer.verify(token) == {:error, :invalid_token}
    end

    test "records with native or invalid scopes never verify", %{state: state} do
      for scopes <- [
            ["incus.native.read"],
            ["incus.read", "incus.native.instances.write"],
            ["incus.read", "incus.read"],
            ["admin"],
            []
          ] do
        {token, record} = AuthFixtures.token!(["incus.read"])
        AuthFixtures.store!(state, [%{record | "scopes" => scopes}])
        assert Bearer.verify(token) == {:error, :invalid_token}, inspect(scopes)
      end
    end

    test "nothing verifies without a usable store", %{state: state, uid: uid} do
      {token, record} = AuthFixtures.token!(["incus.read"])

      # Missing store.
      assert Bearer.verify(token) == {:error, :invalid_token}

      # Group- or world-readable store.
      path = AuthFixtures.store!(state, [record], 0o644)
      assert Bearer.load(path, uid) == {:error, :unsafe}
      assert Bearer.verify(token) == {:error, :invalid_token}

      # A symbolic link to an otherwise valid store.
      real = Path.join(state, "real.json")
      File.rename!(path, real)
      File.chmod!(real, 0o600)
      File.ln_s!(real, path)
      assert Bearer.load(path, uid) == {:error, :unsafe}
      assert Bearer.verify(token) == {:error, :invalid_token}
      File.rm!(path)

      # A gateway directory others can read.
      AuthFixtures.store!(state, [record])
      File.chmod!(Path.dirname(path), 0o755)
      assert Bearer.verify(token) == {:error, :invalid_token}
      File.chmod!(Path.dirname(path), 0o700)
      assert {:ok, _} = Bearer.verify(token)

      # Another owner.
      assert Bearer.load(path, uid + 1) == {:error, :unsafe}
    end

    test "a malformed store verifies nothing", %{state: state, uid: uid} do
      {token, record} = AuthFixtures.token!(["incus.read"])
      path = AuthFixtures.store!(state, [record])

      for contents <- [
            "not json",
            ~s({"schema_version":2,"tokens":[]}),
            ~s({"schema_version":1,"tokens":{}}),
            Jason.encode!(%{"schema_version" => 1, "tokens" => [record, record]}),
            Jason.encode!(%{"schema_version" => 1, "tokens" => [record, %{"id" => "x"}]}),
            Jason.encode!(%{
              "schema_version" => 1,
              "tokens" => [%{record | "expires_at" => "tomorrow"}]
            }),
            String.duplicate(" ", 1_048_577)
          ] do
        File.write!(path, contents)
        assert Bearer.load(path, uid) == {:error, :invalid_store}
        assert Bearer.verify(token) == {:error, :invalid_token}
      end
    end

    test "nothing verifies without a configured owner or state", %{state: state} do
      {token, record} = AuthFixtures.token!(["incus.read"])
      AuthFixtures.store!(state, [record])

      Application.delete_env(:macus, Macus.Auth)
      assert Bearer.verify(token) == {:error, :invalid_token}

      Application.put_env(:macus, Macus.Auth, owner_uid: "501")
      assert Bearer.verify(token) == {:error, :invalid_token}

      Application.put_env(:macus, Macus.Auth, owner_uid: File.stat!(state).uid)
      Application.put_env(:macus, :state_dir, "relative/state")
      assert Bearer.verify(token) == {:error, :invalid_token}
    end
  end
end
