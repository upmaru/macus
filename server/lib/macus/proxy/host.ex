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

  ## Migration peers

  Another Incus server taking part in an instance, snapshot or volume copy
  through the gateway (pulling from Macus, or pushing into it) dials the
  migration operation's WebSocket with one of its channel secrets and no
  gateway certificate. `admit_operation_secret/2` admits it only when the
  named operation is a running migration in the guest Incus, read over
  `incus.sock` at admission time: a `websocket`-class operation whose metadata
  is exactly its migration channel secrets (`control`, plus `fs` or the legacy
  `criu`), one of which the presented secret matches in constant time. Exec and
  console operations, which nest their secrets under `fds`, are never matched.
  Only a well-formed request (a UUID operation and a 64-character lowercase
  hex secret, as incusd generates them) causes that single read-only lookup;
  anything else is refused without reading the guest.
  The project is resolved from the operation when the native helper omits it,
  and an explicit project must match the operation's. A cluster target is
  refused. The guest also checks the secret itself when the channel connects.
  The grant lasts at most the native exchange lifetime.

  ## Image-copy peers

  Another Incus server copying an image through the gateway has no gateway
  certificate. When `incus image copy` (or another client holding both
  servers) pulls an image from Macus or pushes one into it, that server reaches
  exactly one of the shared gateway's image secret routes: image info or
  export (pull), or the upload and its operation wait (push).
  `admit_image_secret/2` admits it only when its secret matches an operation
  pending in the guest Incus, read over the same `incus.sock` at admission
  time: for info, export and upload, an image token (`token` class) whose
  `images` resource names the fingerprint, which an authorized caller created
  through the gateway (`POST /1.0/images/{fp}/secret`, or a push-mode
  `POST /1.0/images`); for a wait, the named operation. The guest Incus
  treats the gateway's socket as trusted and does not check image secrets
  itself, so this comparison (in constant time) is the check. A secret that is
  not 64 lowercase hex characters, or a wait on a non-UUID operation, is
  refused without reading the guest. The forwarded
  secret still consumes the single-use token, as natively. A cluster target is
  refused. The grant lasts at most the native exchange lifetime. Instance and
  volume migration peers are not admitted.

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
  alias Opsmaru.Incus.{Connection, Context}
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

  def valid?(%Request{}, %{peer: kind, expires: expires}, config)
      when kind in [:image, :migration],
      do: DateTime.compare(now(config), expires) == :lt

  def valid?(_request, _grant, _config), do: false

  # Server peers

  @image_routes [:info, :export, :upload, :wait]
  # incusd operation IDs are UUIDs and its migration and image secrets are
  # 32 random bytes in lowercase hex; anything else is refused before the
  # guest is read.
  @operation_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @secret_format ~r/\A[0-9a-f]{64}\z/
  @migration_channels ["control", "fs", "criu"]
  @default_peer_ttl 3_600_000

  @impl true
  def admit_operation_secret(%Request{query: query} = request, config) do
    with nil <- request.target,
         {:ok, secret} <- single_secret(query),
         {:ok, [operation]} <- pending_operations(config, request, :wait),
         true <- migration?(operation, request.operation, secret),
         true <- request.project in [nil, operation_project(operation)] do
      {:ok, peer_grant(:migration, config)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def admit_operation_secret(_request, _config), do: {:error, :forbidden}

  defp single_secret(query) do
    case for {"secret", value} <- URI.query_decoder(query || ""), do: value do
      [secret] -> if secret =~ @secret_format, do: {:ok, secret}, else: :error
      _ -> :error
    end
  end

  # A running migration's metadata is exactly its channel secrets.
  defp migration?(
         %{"id" => id, "class" => "websocket", "status" => "Running"} = operation,
         id,
         secret
       ) do
    case operation["metadata"] do
      %{"control" => control} = channels when is_binary(control) ->
        Enum.all?(channels, fn {name, value} ->
          name in @migration_channels and is_binary(value)
        end) and
          Enum.any?(Map.values(channels), &Plug.Crypto.secure_compare(&1, secret))

      _ ->
        false
    end
  end

  defp migration?(_operation, _id, _secret), do: false

  # Rendered resource URLs carry the project for a nondefault project.
  defp operation_project(operation) do
    (operation["resources"] || %{})
    |> Map.values()
    |> Enum.filter(&is_list/1)
    |> Enum.concat()
    |> Enum.find_value("default", fn url ->
      is_binary(url) && URI.decode_query(URI.parse(url).query || "")["project"]
    end)
  end

  defp peer_grant(kind, config) do
    ttl = Map.get(config, :peer_grant_ttl, @default_peer_ttl)
    %{peer: kind, expires: DateTime.add(now(config), ttl, :millisecond)}
  end

  @impl true
  def admit_image_secret(%{image: %{route: route, secret: secret} = image} = request, config)
      when route in @image_routes and is_binary(secret) do
    with nil <- request.target,
         true <- secret =~ @secret_format,
         {:ok, operations} <- pending_operations(config, request, route),
         true <- Enum.any?(operations, &pending?(&1, route, image, request.operation, secret)) do
      {:ok, peer_grant(:image, config)}
    else
      _ -> {:error, :forbidden}
    end
  end

  def admit_image_secret(_request, _config), do: {:error, :forbidden}

  defp pending_operations(config, request, :wait) do
    if is_binary(request.operation) and request.operation =~ @operation_id do
      with {:ok, operation} <-
             backend_get(config, request, "/1.0/operations/#{request.operation}"),
           do: {:ok, [operation]}
    else
      :error
    end
  end

  defp pending_operations(config, request, _route) do
    with {:ok, groups} when is_map(groups) <-
           backend_get(config, request, "/1.0/operations?recursion=1") do
      {:ok, groups |> Map.values() |> Enum.filter(&is_list/1) |> Enum.concat()}
    end
  end

  # One bounded read of the guest Incus over the gateway's own connection,
  # in the request's project. It runs inside the gateway's callback deadline.
  defp backend_get(%{connection: %Connection{} = connection}, request, path) do
    connection = Connection.project(connection, request.project || "default")

    context =
      Context.new!(owner: connection.owner, identity: :image_peer, ready?: fn -> true end)

    case Opsmaru.Incus.raw_query(connection, context, "GET", path, []) do
      {:ok, %{metadata: metadata}} -> {:ok, metadata}
      _ -> :error
    end
  end

  defp backend_get(_config, _request, _path), do: :error

  # As incusd's imageValidSecret: a token whose images resource starts with
  # the requested fingerprint and whose secret matches, whether or not its
  # first use already cancelled it.
  defp pending?(%{"class" => "token"} = operation, route, image, _id, secret)
       when route in [:info, :export, :upload] do
    images = get_in(operation, ["resources", "images"]) || []

    is_binary(image.fingerprint) and is_list(images) and
      Enum.any?(
        images,
        &(is_binary(&1) and String.starts_with?(&1, "/1.0/images/" <> image.fingerprint))
      ) and
      secret?(operation, secret)
  end

  defp pending?(%{"id" => id} = operation, :wait, _image, id, secret),
    do: secret?(operation, secret)

  defp pending?(_operation, _route, _image, _id, _secret), do: false

  defp secret?(operation, secret) do
    case get_in(operation, ["metadata", "secret"]) do
      expected when is_binary(expected) -> Plug.Crypto.secure_compare(expected, secret)
      _ -> false
    end
  end

  # Public identity

  @impl true
  def identity(_request, %{identity: identity, connection: connection}) do
    with {:ok, origin} <- Keyword.fetch(identity, :origin),
         {:ok, addresses} <- Keyword.fetch(identity, :addresses),
         {:ok, certificate} <- identity_certificate(identity),
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

  # The running gateway supplies its checked leaf certificate; otherwise it
  # is read from the configured file.
  defp identity_certificate(identity) do
    case Keyword.fetch(identity, :certificate) do
      {:ok, pem} when is_binary(pem) ->
        with {:ok, der} <- Trust.der(pem), do: {:ok, Trust.pem(der)}

      _ ->
        with {:ok, file} <- Keyword.fetch(identity, :certificate_file),
             do: public_certificate(file)
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
