defmodule Macus.Auth.StreamsTest do
  # The state directory, owner and stream registry are global.
  use ExUnit.Case, async: false

  alias Macus.Auth.{Bearer, Streams}
  alias Macus.Auth.Streams.Watcher
  alias Macus.TestSupport.{AuthFixtures, DexFixtures}

  @revoked {:shutdown, :credential_revoked}

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)
    %{state: state}
  end

  # A stream process registered for `token`, as `Macus.MCP.Authorization`
  # registers a request.
  defp stream!(token, opts \\ []) do
    test = self()

    pid =
      spawn(fn ->
        if Keyword.get(opts, :trap, false), do: Process.flag(:trap_exit, true)
        {:ok, verified} = Bearer.verify(token)

        send(
          test,
          {:registered, self(), Streams.register(verified.credential, verified.expires_at)}
        )

        hold()
      end)

    assert_receive {:registered, ^pid, :ok}
    Process.monitor(pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, attempts - 1)
    end
  end

  defp hold do
    receive do
      :stop -> :ok
      _other -> hold()
    end
  end

  # A manual watcher over only this test's processes, with an injected clock.
  defp watcher!(pids, opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    start_supervised!(
      {Watcher,
       Keyword.merge(
         [
           name: nil,
           interval_ms: :manual,
           grace_ms: 50,
           clock: clock,
           entries: fn -> Enum.filter(Streams.entries(), fn {pid, _} -> pid in pids end) end
         ],
         Keyword.drop(opts, [:clock])
       )}
    )
  end

  defp revoke!(state, records, id) do
    AuthFixtures.store!(
      state,
      Enum.map(records, fn
        %{"id" => ^id} = record -> %{record | "revoked_at" => "2026-01-01T00:00:00Z"}
        record -> record
      end)
    )
  end

  test "the documented bound is 5 seconds, checked every 4.5 seconds" do
    assert Streams.timing() == {5_000, 500}
    assert Streams.bound_ms() == 5_000
  end

  test "a valid credential's streams stay open", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    AuthFixtures.store!(state, [record])
    pid = stream!(token)
    watcher = watcher!([pid])

    assert Watcher.check(watcher) == []
    assert Process.alive?(pid)
  end

  test "revocation closes only that credential's streams", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    {other, other_record} = AuthFixtures.token!(["incus.read"])
    records = [record, other_record]
    AuthFixtures.store!(state, records)
    first = stream!(token)
    second = stream!(token)
    unaffected = stream!(other)
    watcher = watcher!([first, second, unaffected])

    revoke!(state, records, record["id"])
    assert Enum.sort(Watcher.check(watcher)) == Enum.sort([first, second])
    assert_receive {:DOWN, _, :process, ^first, @revoked}
    assert_receive {:DOWN, _, :process, ^second, @revoked}
    assert Process.alive?(unaffected)

    # New requests with the revoked token are refused too.
    assert Bearer.verify(token) == {:error, :invalid_token}
  end

  test "expiry closes streams when the clock passes it", %{state: state} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires = DateTime.add(now, 3_600)
    {token, record} = AuthFixtures.token!(["incus.read"], expires_at: expires)
    AuthFixtures.store!(state, [record])
    pid = stream!(token)

    {:ok, clock} = Agent.start_link(fn -> DateTime.add(expires, -1) end)
    watcher = watcher!([pid], clock: fn -> Agent.get(clock, & &1) end)

    assert Watcher.check(watcher) == []
    Agent.update(clock, fn _ -> expires end)
    assert Watcher.check(watcher) == [pid]
    assert_receive {:DOWN, _, :process, ^pid, @revoked}
  end

  test "a removed, replaced or rescoped record closes its streams", %{state: state} do
    for change <- [
          fn _record -> [] end,
          fn record -> [%{record | "verifier" => String.duplicate("b", 64)}] end,
          fn record -> [%{record | "scopes" => ["incus.read", "incus.write"]}] end,
          fn record -> [%{record | "scopes" => ["incus.native.read"]}] end
        ] do
      {token, record} = AuthFixtures.token!(["incus.read"])
      AuthFixtures.store!(state, [record])
      pid = stream!(token)
      watcher = watcher!([pid])

      AuthFixtures.store!(state, change.(record))
      assert Watcher.check(watcher) == [pid]
      assert_receive {:DOWN, _, :process, ^pid, @revoked}
      stop_supervised!(Watcher)
    end
  end

  test "an unreadable store closes every bearer stream", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    path = AuthFixtures.store!(state, [record])
    pid = stream!(token)
    watcher = watcher!([pid])

    File.chmod!(path, 0o644)
    assert Watcher.check(watcher) == [pid]
    assert_receive {:DOWN, _, :process, ^pid, @revoked}
  end

  test "a stream that traps the exit is killed after the grace period", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    AuthFixtures.store!(state, [record])
    pid = stream!(token, trap: true)
    watcher = watcher!([pid], grace_ms: 30)

    AuthFixtures.store!(state, [])
    assert Watcher.check(watcher) == [pid]
    assert Process.alive?(pid)
    assert_receive {:DOWN, _, :process, ^pid, :killed}, 1_000
  end

  test "an unregistered or finished stream is not tracked", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    AuthFixtures.store!(state, [record])
    {:ok, verified} = Bearer.verify(token)

    assert Streams.register(verified.credential, verified.expires_at) == :ok
    assert Enum.any?(Streams.entries(), fn {pid, _} -> pid == self() end)
    assert Streams.unregister() == :ok
    refute Enum.any?(Streams.entries(), fn {pid, _} -> pid == self() end)

    pid = stream!(token)
    send(pid, :stop)
    assert_receive {:DOWN, _, :process, ^pid, :normal}
    # The registry drops an exited process's entry asynchronously.
    assert eventually(fn ->
             not Enum.any?(Streams.entries(), fn {entry, _} -> entry == pid end)
           end)

    assert Streams.register(:unknown, nil) == :error
    assert Streams.register({:bearer, "id", "verifier", ["incus.read"]}, "never") == :error
  end

  test "a timed watcher closes a revoked stream within its interval plus grace", %{state: state} do
    {token, record} = AuthFixtures.token!(["incus.read"])
    AuthFixtures.store!(state, [record])
    pid = stream!(token)
    watcher!([pid], interval_ms: 40, grace_ms: 20)

    refute_receive {:DOWN, _, :process, ^pid, _}, 100
    revoked_at = System.monotonic_time(:millisecond)
    AuthFixtures.store!(state, [])
    assert_receive {:DOWN, _, :process, ^pid, @revoked}, 1_000
    assert System.monotonic_time(:millisecond) - revoked_at <= 40 + 20 + 200
  end
end
