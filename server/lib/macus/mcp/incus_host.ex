defmodule Macus.MCP.IncusHost do
  @moduledoc """
  The Macus `Opsmaru.Incus.Operations.Host`: every trust decision for shared
  Incus operations run through `execute`.

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
    its directory.
  - `:owner_key`: the owner key verified callers carry (required).
  - `:ready`: `{module, function, args}` returning `true` when the host
    identity and Incus backend are ready (required; without it nothing is
    dispatched).
  - `:image_remotes`: approved remotes, `%{name => %{"server" =>
    "https://...", "protocol" => "simplestreams" | "incus" | "oci"}}`.
    Default `%{}`.
  - `:restricted`: allowed restricted items, each `{:config, key}` or
    `{:device, name}`. Default `[]`.
  - `:projects`: the native projects callers may name in input, `:all` or a
    list of names. Default `:all`, matching the initial owner-admin policy;
    input without `project` uses the native default project.
  - `:timeout`: the per-request deadline in milliseconds, which also bounds
    an operation's wait. Default 30 000.

  Invalid or missing configuration denies every call.
  """

  @behaviour Opsmaru.Incus.Operations.Host

  alias Macus.{Configuration, PrivatePath}
  alias Opsmaru.Incus.{Connection, Context}
  alias Opsmaru.Incus.Operations.Composite

  @protocols ["simplestreams", "incus", "oci"]
  @default_timeout 30_000

  @impl true
  def binding(caller, operation) do
    with {:ok, config} <- config(),
         {:ok, principal} <- verify(caller, config),
         {:ok, _descriptor} <- descriptor(operation) do
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
  end

  @impl true
  def authorize(caller, operation, input) when is_map(input) do
    with {:ok, config} <- config(),
         {:ok, _principal} <- verify(caller, config),
         {:ok, descriptor} <- descriptor(operation) do
      # The executor passes the scopes tama-dex checked; they must also be
      # the verified caller's own.
      cond do
        descriptor.scope not in caller.scopes -> {:error, :forbidden}
        not project_allowed?(config.projects, input) -> {:error, :forbidden_project}
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

  defp project_allowed?(:all, _input), do: true
  defp project_allowed?(projects, %{"project" => project}), do: project in projects
  defp project_allowed?(_projects, _input), do: true

  defp descriptor(operation) when is_binary(operation) do
    case Composite.fetch(operation) do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> {:error, :unknown_operation}
    end
  end

  defp descriptor(_operation), do: {:error, :unknown_operation}

  defp ready?(config, socket) do
    {module, function, args} = config.ready

    apply(module, function, args) == true and
      PrivatePath.private_dir(Path.dirname(socket), config.owner_uid) == :ok and
      PrivatePath.private_entry(socket, config.owner_uid, :socket) == :ok
  end

  # Read per call, so a configuration change takes effect without a restart
  # and an invalid one denies instead of crashing.
  defp config do
    env = Application.get_env(:macus, __MODULE__, [])

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
