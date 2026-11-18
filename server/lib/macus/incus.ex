defmodule Macus.Incus do
  @moduledoc """
  Consumer boundary for the shared `:opsmaru_incus` library.

  `:opsmaru_incus` is a pure library: it has no application callback, so
  loading or starting it creates no process, listener, state or backend
  connection, whatever `PHX_SERVER` or `PORT` say. Macus supplies every
  backend explicitly. The private connection is always the owner's
  `<state-dir>/incus.sock` and the trusted host context carries the
  verified owner and a readiness check (`Macus.MCP.IncusHost`). Portable
  codecs, version and extension checks, native errors and client parity
  belong to the library; Macus implements none of them.

  ## Host-supervised client workers

  With the serving gateway, Macus also starts the library's optional
  `Opsmaru.Incus.ClientSupervisor` as `Macus.Incus.Clients`, so client work
  that should not run in a request process (`run/3`) has bounded
  concurrency. It holds no queue: a call at capacity fails at once. Starting
  or restarting it does no startup or recovery work and opens nothing; it
  never starts, stops or deletes the VM or its workloads. Losing a worker
  does not cancel work Incus may already have accepted, and nothing is
  retried.

      config :macus, Macus.Incus, client_workers: 16   # 1..1024, or false

  Without a serving gateway nothing starts.
  """

  alias Macus.MCP.IncusHost
  alias Opsmaru.Incus.ClientSupervisor

  @supervisor Macus.Incus.Clients
  @default_workers 16
  @default_timeout 30_000

  @doc "The client worker supervisor's name."
  @spec supervisor() :: atom()
  def supervisor, do: @supervisor

  @doc """
  Children for the server's tree: the client worker supervisor while the
  gateway serves, unless `client_workers: false`. An invalid
  `client_workers` raises, so a bad configuration fails startup.
  """
  @spec child_specs(Macus.Gateway.t() | nil) :: [Supervisor.child_spec()]
  def child_specs(nil), do: []

  def child_specs(%Macus.Gateway{}) do
    case Keyword.get(
           Application.get_env(:macus, __MODULE__, []),
           :client_workers,
           @default_workers
         ) do
      false -> []
      workers -> [ClientSupervisor.child_spec(name: @supervisor, max_children: workers)]
    end
  end

  @doc """
  Runs `fun.(client)` on a client worker with the verified caller's shared
  client (`Macus.MCP.IncusHost.client/1`), and returns its result.

  The client connects inside the worker, so nothing reaches `incus.sock`
  until the host is ready: before that the result is the library's
  `host_not_ready` error and no request is sent. Other failures are
  `{:error, :capacity}` (every worker busy), `{:error,
  :supervisor_unavailable}` (no worker supervisor), `{:error, :timeout}`
  (the local deadline passed; the worker is stopped, but work Incus
  accepted is not cancelled) and `{:error, :worker_exited}`.

  Options: `:timeout` in milliseconds (default 30 000).
  """
  @spec run(TamaMCP.Context.t(), (Opsmaru.Incus.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def run(caller, fun, opts \\ []) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    work = fn ->
      case IncusHost.client(caller) do
        {:ok, client} -> fun.(client)
        {:error, _} = error -> error
      end
    end

    with {:ok, task} <- ClientSupervisor.async(@supervisor, work) do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _reason} -> {:error, :worker_exited}
        nil -> {:error, :timeout}
      end
    end
  end
end
