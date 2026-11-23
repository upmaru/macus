defmodule Macus.MCP.IncusHost do
  @moduledoc """
  The Macus `Opsmaru.Incus.Operations.Host`: every trust decision for shared
  Incus operations run through `execute`, composite
  (`Opsmaru.Incus.Operations.Composite`) and native
  (`Opsmaru.Incus.Operations.Native`) alike. Each needs its own scope in the
  caller's verified scopes.

  The `caller` is the verified `TamaMCP.Context` that tama-dex passes to the
  executor. Only its `principal`, `owner_key` and `scopes` are read, and
  `owner_key` must equal the configured gateway owner. Tool input never
  selects the backend: the socket is always `<state-dir>/incus.sock`, from
  trusted configuration, and the shared operation schemas reject unknown
  input fields such as an owner, URL or socket before the host is asked.

  Readiness gates dispatch. The `Opsmaru.Incus.Context` handed to the
  library carries a `ready?` check that it runs before every backend
  request: the configured readiness function must return `true` and
  `incus.sock` must be an owner-private socket in an owner-private
  directory. Until then every call fails with `host_not_ready` and nothing
  is sent.

  Image remotes and restricted create/update input are denied unless the
  configuration names them.

  ## Configuration

  The state directory is `config :macus, :state_dir`. Host settings are
  `config :macus, Macus.MCP.IncusHost, ...`:

  - `:owner_uid`: the verified host owner, who must own `incus.sock` and
    its directory. Defaults to the serving gateway's owner.
  - `:owner_key`: the owner key verified callers carry. Defaults to the
    serving gateway owner's `Macus.Auth.owner_key/1`.
  - `:ready`: `{module, function, args}` returning `true` when the host
    identity and Incus backend are ready. Defaults to
    `Macus.Gateway.serving?/0` while the gateway serves; without a serving
    gateway or this setting nothing is dispatched.
  - `:image_remotes`: approved remotes, `%{name => %{"server" =>
    "https://...", "protocol" => "simplestreams" | "incus" | "oci"}}`.
    Default `%{}`.
  - `:restricted`: allowed restricted items, each `{:config, key}` or
    `{:device, name}`. Default `[]`.
  - `:projects`: the native projects callers may name in input, `:all` or a
    list of names. Default `:all`, matching the initial owner-admin policy.
    An operation that selects a project and is called without `project`
    reaches Incus's `default` project, so it is allowed only when
    `"default"` is listed.
  - `:timeout`: the per-request deadline in milliseconds, which also bounds
    an operation's wait. Default 30 000.

  Invalid or missing configuration denies every call.
  """

  @behaviour Opsmaru.Incus.Operations.Host

  alias Macus.{Configuration, PrivatePath}
  alias Opsmaru.Incus.{Connection, Context}
  alias Opsmaru.Incus.Operations.{Composite, Native}

  @protocols ["simplestreams", "incus", "oci"]
  @default_timeout 30_000

  # Native operation scopes, read from the library's generated document.
  @native_scopes Map.new(Native.openapi()["paths"], fn {_, %{"post" => operation}} ->
                   {operation["operationId"], hd(operation["x-tama-scopes"])}
                 end)

  # Native operations whose input selects a project.
  @native_projected for {_, %{"post" => operation}} <- Native.openapi()["paths"],
                        properties =
                          get_in(operation, [
                            "requestBody",
                            "content",
                            "application/json",
                            "schema",
                            "properties"
                          ]) || %{},
                        Map.has_key?(properties, "project"),
                        into: MapSet.new(),
                        do: operation["operationId"]

  @impl true
  def binding(caller, operation) do
    with {:ok, config} <- config(),
         {:ok, principal} <- verify(caller, config),
         {:ok, _scope} <- scope(operation) do
      backend(config, principal)
    end
  end

  @doc """
  The shared `Opsmaru.Incus` client for a verified caller, on the same
  owner-bound `incus.sock` connection and readiness check that operations
  use. For the library's file, transfer, event, console, copy and raw
  upgrade clients, which have no operation of their own; the caller's
  scopes are the consumer's to check.
  """
  @spec client(TamaMCP.Context.t()) :: {:ok, Opsmaru.Incus.t()} | {:error, term()}
  def client(caller) do
    with {:ok, config} <- config(),
         {:ok, principal} <- verify(caller, config),
         {:ok, connection, context} <- backend(config, principal) do
      Opsmaru.Incus.connect(connection, context)
    end
  end

  defp backend(config, principal) do
    socket = Configuration.incus_socket(config.state)
    owner = {:macus, config.owner_key}

    connection = Connection.unix!(socket, owner: owner, timeout: config.timeout)

    context =
      Context.new!(
        owner: owner,
        identity: principal,
        ready?: fn -> ready?(config, socket) end
      )

    {:ok, connection, context}
  end

  @impl true
  def authorize(caller, operation, input) when is_map(input) do
    with {:ok, config} <- config(),
         {:ok, _principal} <- verify(caller, config),
         {:ok, scope} <- scope(operation) do
      # The executor passes the scopes tama-dex checked; they must also be
      # the verified caller's own.
      cond do
        scope not in caller.scopes -> {:error, :forbidden}
        not project_allowed?(config.projects, operation, input) -> {:error, :forbidden_project}
        true -> :ok
      end
    end
  end

  def authorize(_caller, _operation, _input), do: {:error, :invalid_input}

  @impl true
  def image_remote(caller, name) do
    with {:ok, config} <- config(),
         {:ok, _principal} <- verify(caller, config) do
      case Map.fetch(config.image_remotes, name) do
        {:ok, remote} -> {:ok, remote}
        :error -> {:error, :not_approved}
      end
    end
  end

  @impl true
  def allow_restricted?(caller, _operation, items) do
    with {:ok, config} <- config(),
         {:ok, _principal} <- verify(caller, config) do
      is_list(items) and items != [] and Enum.all?(items, &(&1 in config.restricted))
    else
      _ -> false
    end
  end

  defp verify(
         %TamaMCP.Context{principal: principal, owner_key: key, scopes: scopes},
         %{owner_key: key}
       )
       when not is_nil(principal) and not is_nil(key) and is_list(scopes),
       do: {:ok, principal}

  defp verify(_caller, _config), do: {:error, :unauthenticated}

  # An operation that selects a project is checked against the list with the
  # project it will reach: the named one, or Incus's default when omitted.
  defp project_allowed?(:all, _operation, _input), do: true

  defp project_allowed?(projects, operation, input) do
    cond do
      Map.has_key?(input, "project") -> input["project"] in projects
      projected?(operation) -> "default" in projects
      true -> true
    end
  end

  defp projected?(operation) do
    case Composite.fetch(operation) do
      {:ok, descriptor} ->
        Map.has_key?(descriptor.input_schema["properties"] || %{}, "project")

      :error ->
        MapSet.member?(@native_projected, operation)
    end
  end

  # The scope a composite or native operation requires.
  defp scope(operation) when is_binary(operation) do
    case Composite.fetch(operation) do
      {:ok, descriptor} ->
        {:ok, descriptor.scope}

      :error ->
        case Map.fetch(@native_scopes, operation) do
          {:ok, scope} -> {:ok, scope}
          :error -> {:error, :unknown_operation}
        end
    end
  end

  defp scope(_operation), do: {:error, :unknown_operation}

  defp ready?(config, socket) do
    {module, function, args} = config.ready

    apply(module, function, args) == true and
      PrivatePath.private_dir(Path.dirname(socket), config.owner_uid) == :ok and
      PrivatePath.private_entry(socket, config.owner_uid, :socket) == :ok
  end

  # Read per call, so a configuration change takes effect without a restart
  # and an invalid one denies instead of crashing.
  defp config do
    env =
      Application.get_env(:macus, __MODULE__, [])
      |> Macus.Auth.owner_defaults()
      |> default_ready()

    with {:ok, state} <- Configuration.new(Application.get_env(:macus, :state_dir)),
         {:ok, uid} <- fetch(env, :owner_uid, &(is_integer(&1) and &1 >= 0)),
         {:ok, key} <- fetch(env, :owner_key, &(not is_nil(&1))),
         {:ok, ready} <- fetch(env, :ready, &mfa?/1),
         {:ok, remotes} <- fetch(env, :image_remotes, %{}, &remotes?/1),
         {:ok, restricted} <- fetch(env, :restricted, [], &restricted?/1),
         {:ok, projects} <- fetch(env, :projects, :all, &projects?/1),
         {:ok, timeout} <- fetch(env, :timeout, @default_timeout, &(&1 in 1..3_600_000)) do
      {:ok,
       %{
         state: state,
         owner_uid: uid,
         owner_key: key,
         ready: ready,
         image_remotes: remotes,
         restricted: restricted,
         projects: projects,
         timeout: timeout
       }}
    else
      _ -> {:error, :host_unconfigured}
    end
  end

  # While the gateway serves, its own identity check is the default
  # readiness; without it nothing is dispatched.
  defp default_ready(env) do
    if Macus.Gateway.serving?(),
      do: Keyword.put_new(env, :ready, {Macus.Gateway, :serving?, []}),
      else: env
  end

  defp fetch(env, key, valid?) do
    case Keyword.fetch(env, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp fetch(env, key, default, valid?) do
    value = Keyword.get(env, key, default)
    if valid?.(value), do: {:ok, value}, else: :error
  end

  defp mfa?({module, function, args}) when is_atom(module) and is_atom(function),
    do: is_list(args)

  defp mfa?(_), do: false

  defp remotes?(remotes) when is_map(remotes) do
    Enum.all?(remotes, fn
      {name, %{"server" => "https://" <> _ = server, "protocol" => protocol} = remote}
      when is_binary(name) and map_size(remote) == 2 ->
        protocol in @protocols and URI.parse(server).host not in [nil, ""]

      _ ->
        false
    end)
  end

  defp remotes?(_), do: false

  defp restricted?(items) when is_list(items) do
    Enum.all?(items, fn
      {kind, name} when kind in [:config, :device] -> is_binary(name)
      _ -> false
    end)
  end

  defp restricted?(_), do: false

  defp projects?(:all), do: true
  defp projects?(projects) when is_list(projects), do: Enum.all?(projects, &is_binary/1)
  defp projects?(_), do: false
end
