defmodule Macus.Auth.Streams.Watcher do
  @moduledoc """
  Rechecks registered stream credentials every `bound_ms - grace_ms`
  (default 4.5 s) and terminates the processes of invalid ones with
  `{:shutdown, :credential_revoked}`. A process still alive `grace_ms`
  later (it trapped the exit) is killed, so closure completes within
  `bound_ms` of the revocation or expiry.

  The application's watcher uses `Macus.Auth.Streams.timing/0`; the test
  environment sets `config :macus, Macus.Auth.Streams, interval_ms: :manual`
  so checks happen only when a test calls `check/1`.

  Options:

    * `:name` - registered name (default `#{inspect(__MODULE__)}`; `nil` for none)
    * `:interval_ms` - check interval, or `:manual` to check only on `check/1`
    * `:grace_ms` - wait before killing a process that survived termination
    * `:clock` - zero-arity function returning the current `DateTime`
    * `:entries` - zero-arity function returning the entries to check
  """

  use GenServer

  require Logger

  alias Macus.Auth.Streams

  @reason {:shutdown, :credential_revoked}

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Checks every registered credential now and returns the terminated
  processes.
  """
  @spec check(GenServer.server()) :: [pid()]
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @impl true
  def init(opts) do
    {bound, grace} = Streams.timing()

    state = %{
      interval:
        opts
        |> Keyword.get_lazy(:interval_ms, fn ->
          Keyword.get(Application.get_env(:macus, Streams, []), :interval_ms)
        end)
        |> interval(bound - grace),
      grace: Keyword.get(opts, :grace_ms, grace),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      entries: Keyword.get(opts, :entries, &Streams.entries/0)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state), do: {:reply, run(state), state}

  @impl true
  def handle_info(:check, state) do
    run(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:enforce, pid}, state) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run(state) do
    entries = state.entries.()

    pids =
      entries
      |> Streams.invalid(state.clock.())
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    for pid <- pids do
      Process.exit(pid, @reason)
      Process.send_after(self(), {:enforce, pid}, state.grace)
    end

    if pids != [] do
      :telemetry.execute([:macus, :auth, :streams, :closed], %{count: length(pids)}, %{})
      Logger.info("Closed #{length(pids)} stream(s) of revoked or expired credentials")
    end

    pids
  end

  # An interval never exceeds `bound_ms - grace_ms`, keeping the bound.
  defp interval(:manual, _limit), do: :manual
  defp interval(ms, limit) when is_integer(ms) and ms > 0, do: min(ms, limit)
  defp interval(_ms, limit), do: limit

  defp schedule(%{interval: :manual}), do: :ok

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :check, interval)
end
