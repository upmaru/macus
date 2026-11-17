defmodule Macus.Proxy.Host do
  @moduledoc """
  Macus host policy for the shared native gateway
  (`Opsmaru.Incus.Gateway.Host`).

  ## Authentication

  A native request is authenticated only by the TLS peer certificate the
  server adapter collected: its SHA-256 fingerprint must be in the gateway's
  own trust store (`Macus.Proxy.Trust`), the stored certificate must be
  exactly that certificate, and it must be within its validity period. The
  grant is rechecked (`valid?/3`) before backend access and during every
  exchange, so removing a certificate or reaching its expiry ends its
  requests and streams within the gateway recheck interval (5 s). Bearer
  headers, request bodies and anything the guest Incus trusts are never
  identity. Without a trusted certificate the request is unauthenticated:
  only the synthetic discovery responses and token enrollment are answered,
  without backend access.

  ## Enrollment

  An untrusted client presenting a TLS certificate enrolls with a native
  `trust_token` (`POST /1.0/certificates`, as `incus remote add NAME TOKEN`
  sends it). The token must be an unconsumed, unrevoked, unexpired gateway
  enrollment token (`Macus.Proxy.Enrollment`), which is consumed before the
  certificate is trusted; the certificate must be within its validity
  period. Any other unauthenticated certificate request is refused with
  403, and native server-side token issuance (`"token": true`), restricted
  and project-scoped requests are refused by the shared gateway with 400.

  ## Public identity

  `identity/2` returns only explicitly configured public metadata: the
  HTTPS origin, the advertised `host:port` addresses, the gateway
  certificate PEM and the verified backend API extensions. It never probes
  the guest. The shared gateway serves it as the anonymous `/` and `/1.0`
  responses and substitutes it into an authenticated `/1.0` response, so
  guest certificates and guest-network addresses never reach a client.

  ## Certificate trust

  `certificates/5` implements `/1.0/certificates` against the gateway trust
  store with native shapes: list (URLs, or objects with `recursion`), get
  (with an ETag), create (PEM or base64 DER, or the caller's own certificate
  when empty; 409 when already trusted), update (name, description and
  certificate; `If-Match` checked; the type cannot change) and delete. Every
  certificate is an unrestricted owner-admin client; restricted and
  project-scoped requests are refused by the shared gateway before this
  callback. The guest trust store is never read or changed.
  """

  @behaviour Opsmaru.Incus.Gateway.Host

  alias Macus.Proxy.{Enrollment, Trust}
  alias Opsmaru.Incus.Gateway.Request

  @impl true
  def ready?(%{store: %{uid: uid}, identity: identity})
      when is_integer(uid) and is_list(identity),
      do: true

  def ready?(_config), do: false

  # Authentication

  @impl true
  def authorize(%Request{peer: %{certificate: der}}, config) when is_binary(der) do
    case Trust.lookup(config.store, der, now(config)) do
      {:ok, entry} -> {:ok, %{fingerprint: entry["fingerprint"], certificate: der}}
      :error -> {:error, :unauthenticated}
    end
  end

  def authorize(_request, _config), do: {:error, :unauthenticated}

  @impl true
  def valid?(%Request{}, %{fingerprint: fingerprint, certificate: der}, config) do
    match?({:ok, %{"fingerprint" => ^fingerprint}}, Trust.lookup(config.store, der, now(config)))
  end

  def valid?(_request, _grant, _config), do: false

  # Public identity

  @impl true
  def identity(_request, %{identity: identity, connection: connection}) do
    with {:ok, origin} <- Keyword.fetch(identity, :origin),
         {:ok, addresses} <- Keyword.fetch(identity, :addresses),
         {:ok, file} <- Keyword.fetch(identity, :certificate_file),
         {:ok, certificate} <- public_certificate(file),
         extensions when is_list(extensions) <- Keyword.get(identity, :api_extensions, []) do
      {:ok,
       %{
         origin: origin,
         addresses: addresses,
         certificate: certificate,
         connection: connection,
         api_extensions: extensions
       }}
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  # The gateway certificate is public, but it must be the owner's file and
  # never a link another user could repoint.
  defp public_certificate(file) when is_binary(file) do
    with {:ok, %File.Stat{type: :regular, size: size, mode: mode}} when size <= 65_536 <-
           File.lstat(file),
         0 <- Bitwise.band(mode, 0o022),
         {:ok, pem} <- File.read(file),
         {:ok, der} <- Trust.der(pem) do
      {:ok, Trust.pem(der)}
    else
      _ -> :error
    end
  end

  defp public_certificate(_file), do: :error

  # Certificate trust

  @impl true
  def certificates(:create, %Request{peer: %{certificate: der}}, nil, %{body: body}, config)
      when is_binary(der) and is_map_key(body, "trust_token") do
    # Native token enrollment: only the token and the TLS peer certificate
    # count; every other field comes from the issued token, as natively.
    with {:ok, token} <- Enrollment.decode(body["trust_token"]) |> or_status(403),
         true <- Trust.valid_at?(der, now(config)) || {:error, 400},
         {:ok, fingerprint} <-
           Enrollment.redeem(config.store, token.secret, der, now(config), enrollment(config)) do
      {:ok, nil, [{"location", "/1.0/certificates/#{fingerprint}"}]}
    end
  end

  def certificates(_action, _request, nil, _input, _config), do: {:error, 403}

  def certificates(:list, request, _grant, _input, config) do
    with {:ok, recursion} <- list_options(request.query),
         {:ok, entries} <- Trust.entries(config.store) do
      metadata =
        if recursion,
          do: Enum.map(entries, &native/1),
          else: Enum.map(entries, &"/1.0/certificates/#{&1["fingerprint"]}")

      {:ok, metadata, []}
    else
      {:error, :filter} -> {:error, 400}
      _ -> {:error, 503}
    end
  end

  def certificates(:get, _request, _grant, %{fingerprint: fingerprint}, config) do
    case Trust.entries(config.store) do
      {:ok, entries} ->
        case Enum.find(entries, &(&1["fingerprint"] == fingerprint)) do
          nil -> {:error, 404}
          entry -> {:ok, native(entry), [{"etag", etag(entry)}]}
        end

      _ ->
        {:error, 503}
    end
  end

  def certificates(:create, request, _grant, %{body: body}, config) do
    with {:ok, der} <- submitted(body["certificate"], request),
         true <- Trust.valid_at?(der, now(config)) || {:error, 400},
         {:ok, name} <- text(body, "name", Trust.common_name(der) || peer_name(request), 255),
         {:ok, description} <- text(body, "description", "", 4_096) do
      entry = Trust.entry(der, name, description, now(config))

      Trust.update(config.store, fn entries ->
        if Enum.any?(entries, &(&1["fingerprint"] == entry["fingerprint"])),
          do: {:error, 409},
          else: {:ok, entries ++ [entry], entry["fingerprint"]}
      end)
      |> case do
        {:ok, fingerprint} -> {:ok, nil, [{"location", "/1.0/certificates/#{fingerprint}"}]}
        {:error, status} when is_integer(status) -> {:error, status}
        {:error, _reason} -> {:error, 503}
      end
    end
  end

  def certificates(:update, _request, _grant, input, config) do
    %{fingerprint: fingerprint, body: body, if_match: if_match} = input

    with {:ok, name} <- text(body, "name", "", 255),
         {:ok, description} <- text(body, "description", "", 4_096),
         :ok <- if(Map.get(body, "type", "client") == "client", do: :ok, else: {:error, 400}),
         {:ok, replacement} <- replacement(body["certificate"], config) do
      Trust.update(config.store, fn entries ->
        update(entries, fingerprint, if_match, name, description, replacement)
      end)
      |> case do
        {:ok, :updated} -> {:ok, nil, []}
        {:error, status} when is_integer(status) -> {:error, status}
        {:error, _reason} -> {:error, 503}
      end
    end
  end

  def certificates(:delete, _request, _grant, %{fingerprint: fingerprint}, config) do
    Trust.update(config.store, fn entries ->
      case Enum.split_with(entries, &(&1["fingerprint"] == fingerprint)) do
        {[], _} -> {:error, 404}
        {_, kept} -> {:ok, kept, :deleted}
      end
    end)
    |> case do
      {:ok, :deleted} -> {:ok, nil, []}
      {:error, status} when is_integer(status) -> {:error, status}
      {:error, _reason} -> {:error, 503}
    end
  end

  def certificates(_action, _request, _grant, _input, _config), do: {:error, 405}

  defp update(entries, fingerprint, if_match, name, description, replacement) do
    case Enum.find_index(entries, &(&1["fingerprint"] == fingerprint)) do
      nil ->
        {:error, 404}

      index ->
        current = Enum.at(entries, index)

        cond do
          if_match not in [nil, ""] and String.trim(if_match, "\"") != etag_hash(current) ->
            {:error, 412}

          replacement != nil and
              Enum.any?(
                entries,
                &(&1["fingerprint"] == Trust.fingerprint(replacement) and
                      &1["fingerprint"] != fingerprint)
              ) ->
            {:error, 409}

          true ->
            updated =
              current
              |> Map.merge(%{"name" => name, "description" => description})
              |> replace_certificate(replacement)

            {:ok, List.replace_at(entries, index, updated), :updated}
        end
    end
  end

  defp replace_certificate(entry, nil), do: entry

  defp replace_certificate(entry, der),
    do:
      Map.merge(entry, %{"certificate" => Trust.pem(der), "fingerprint" => Trust.fingerprint(der)})

  # A PUT certificate is PEM, as the native server requires; empty or the
  # same certificate leaves it unchanged.
  defp replacement(value, _config) when value in [nil, ""], do: {:ok, nil}

  defp replacement(value, config) when is_binary(value) do
    case Trust.der(value) do
      {:ok, der} -> if Trust.valid_at?(der, now(config)), do: {:ok, der}, else: {:error, 400}
      :error -> {:error, 400}
    end
  end

  defp replacement(_value, _config), do: {:error, 400}

  # A POST certificate is PEM or base64 DER; empty means the caller's own.
  defp submitted(value, %Request{peer: %{certificate: der}})
       when value in [nil, ""] and is_binary(der),
       do: {:ok, der}

  defp submitted(value, _request) when is_binary(value) and byte_size(value) <= 65_536 do
    case Trust.der(value) do
      {:ok, der} ->
        {:ok, der}

      :error ->
        case Base.decode64(value, ignore: :whitespace) do
          {:ok, der} -> if Trust.certificate?(der), do: {:ok, der}, else: {:error, 400}
          :error -> {:error, 400}
        end
    end
  end

  defp submitted(_value, _request), do: {:error, 400}

  defp text(body, key, default, limit) do
    case Map.get(body, key) do
      value when value in [nil, ""] -> {:ok, default || ""}
      value when is_binary(value) and byte_size(value) <= limit -> {:ok, value}
      _ -> {:error, 400}
    end
  end

  defp peer_name(%Request{peer: %{address: address}}) when is_tuple(address),
    do: address |> :inet.ntoa() |> to_string()

  defp peer_name(_request), do: ""

  defp list_options(query) do
    params = URI.decode_query(query || "")

    cond do
      Map.has_key?(params, "filter") -> {:error, :filter}
      params["recursion"] in [nil, "", "0"] -> {:ok, false}
      true -> {:ok, true}
    end
  end

  @doc false
  def native(entry) do
    %{
      "name" => entry["name"],
      "type" => "client",
      "restricted" => false,
      "projects" => [],
      "certificate" => entry["certificate"],
      "description" => entry["description"],
      "fingerprint" => entry["fingerprint"]
    }
  end

  @doc false
  def etag(entry), do: ~s("#{etag_hash(entry)}")

  # The hash covers the native object in the native field order.
  defp etag_hash(entry) do
    native = native(entry)

    json =
      Jason.encode_to_iodata!(
        Jason.OrderedObject.new(
          for key <- ~w(name type restricted projects certificate description fingerprint),
              do: {key, native[key]}
        )
      )

    Base.encode16(:crypto.hash(:sha256, [json, "\n"]), case: :lower)
  end

  defp or_status(:error, status), do: {:error, status}
  defp or_status(ok, _status), do: ok

  defp enrollment(config), do: Map.get(config, :enrollment) || Enrollment

  defp now(%{clock: clock}) when is_function(clock, 0), do: clock.()
  defp now(_config), do: DateTime.utc_now()
end
