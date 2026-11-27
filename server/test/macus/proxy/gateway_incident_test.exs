defmodule Macus.Proxy.GatewayIncidentTest do
  # Reproduction of the 2026-11-27 native OCI spike gateway fault 1
  # (docs/gateway-incident-2026-11-27.md): a trusted certificate answered
  # `403 unauthorized` after 1-2 s, and an events WebSocket refused as
  # `revoked`, while the host was slow.
  #
  # Macus's own host policy and trust store decide here, unchanged. The only
  # difference from production is `SlowHost`, which delays Macus's answer the
  # way a slow host filesystem delays `Macus.Proxy.Trust.lookup/3` (an
  # owner-private ancestor walk, a stat, a read and a parse on every request
  # and every active-stream recheck). The callback budget is shortened from
  # the production 1 s to keep the tests quick; the decisions do not depend
  # on its length.
  #
  # These tests pin opsmaru_incus 0.2.10 behaviour. Each `# Defect:` assertion
  # is what a fix must invert: a host callback that overruns is not evidence
  # that the certificate is untrusted or was removed.
  use ExUnit.Case, async: false

  alias Macus.Proxy.Trust
  alias Macus.TestSupport.{AuthFixtures, DexFixtures, TLSIdentity}
  alias Opsmaru.Incus.{Connection, Gateway}
  alias Opsmaru.Incus.Gateway.{Admission, Failure, Lease, Policy}

  # The budget each host callback gets (production: 1_000 ms).
  @budget 100

  defmodule SlowHost do
    @moduledoc false
    # Macus.Proxy.Host with a configurable delay before its trust answers.
    @behaviour Opsmaru.Incus.Gateway.Host

    alias Macus.Proxy.Host

    @impl true
    def ready?(config), do: Host.ready?(config)

    @impl true
    def authorize(request, config) do
      Process.sleep(:atomics.get(config.delays, 1))
      Host.authorize(request, config)
    end

    @impl true
    def valid?(request, grant, config) do
      Process.sleep(:atomics.get(config.delays, 2))
      Host.valid?(request, grant, config)
    end

    @impl true
    def identity(request, config), do: Host.identity(request, config)

    @impl true
    def certificates(action, request, grant, input, config),
      do: Host.certificates(action, request, grant, input, config)

    @impl true
    def admit_operation_secret(request, config), do: Host.admit_operation_secret(request, config)

    @impl true
    def admit_image_secret(request, config), do: Host.admit_image_secret(request, config)
  end

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state_dir, uid} = AuthFixtures.state!(root)
    {:ok, state} = Macus.Configuration.new(state_dir)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)
    admin = TLSIdentity.self_signed(certs, "admin")
    trust!(state, [admin])

    admission = start_supervised!({Admission, max_exchanges: 8})
    # authorize/2 delay, valid?/3 delay, in ms.
    delays = :atomics.new(2, signed: false)
    store = %{state: state, uid: uid}

    gateway =
      Gateway.new!(
        # Never dialed: admission decides before any backend contact.
        connection: Connection.unix!(Path.join(state_dir, "incus.sock"), owner: {:macus, "t"}),
        host: SlowHost,
        host_config: %{store: store, identity: [], delays: delays},
        admission: admission,
        callback_timeout: @budget,
        # Lease rechecks every 4 * budget - 2 * budget - 50 ms; each gets the budget.
        recheck_interval: 4 * @budget
      )

    %{gateway: gateway, delays: delays, admin: admin, store: store}
  end

  describe "fault 1: a slow trust answer is reported as an authorization failure" do
    test "a trusted certificate whose lookup overruns gets 403 unauthorized", context do
      request = request(context, :http, "/1.0")

      # Baseline: the same request, answered in time, is the trusted caller.
      assert {:ok, %Policy.Admitted{admitted_as: :caller} = admitted} =
               Policy.admit(context.gateway, request)

      Policy.release(admitted)
      assert {:ok, %{}} = Trust.lookup(context.store, context.admin.der, DateTime.utc_now())

      :atomics.put(context.delays, 1, 3 * @budget)
      started = System.monotonic_time(:millisecond)
      result = Policy.admit(context.gateway, request)
      elapsed = System.monotonic_time(:millisecond) - started

      # Defect: the certificate is still trusted (above), yet the overrun is
      # answered exactly as the incident's access log recorded it — 403,
      # reason `unauthorized`, `admitted_as` absent, after the budget — not as
      # a retryable 503. The incident's 403s took 1005-2310 ms against the
      # production 1 s budget.
      assert {:error, %Failure{status: 403, reason: :unauthorized, outcome: :not_sent}} = result
      assert elapsed >= @budget
    end

    test "an upgrade whose admission recheck overruns is refused as revoked", context do
      request = request(context, :websocket, "/1.0/events")

      # authorize/2 answers in time; the recheck before the relay opens does not.
      :atomics.put(context.delays, 2, 3 * @budget)

      # Defect: the incident's `/1.0/events` refusal (403, `revoked`) for a
      # certificate nobody removed.
      assert {:error, %Failure{status: 403, reason: :revoked}} =
               Policy.admit(context.gateway, request)

      assert {:ok, %{}} = Trust.lookup(context.store, context.admin.der, DateTime.utc_now())
    end

    test "one overrunning recheck ends an open stream as revoked", context do
      test = self()
      request = request(context, :websocket, "/1.0/events")

      # The owner stands in for the relay of an open events WebSocket.
      owner =
        spawn(fn ->
          {:ok, admitted} = Policy.admit(context.gateway, request)

          lease =
            Lease.start(context.gateway, request, admitted, fn reason ->
              send(test, {:interrupted, reason})
            end)

          send(test, {:lease, lease})

          receive do
            {:gateway_stopped, _, reason} -> send(test, {:stopped, reason})
          end

          Process.sleep(:infinity)
        end)

      monitor = Process.monitor(owner)
      assert_receive {:lease, lease}, 1_000

      # Several rechecks pass while the host answers in time.
      Process.sleep(6 * @budget)
      assert Lease.check(lease) == :ok

      # One slow answer: the certificate stays trusted throughout.
      :atomics.put(context.delays, 2, 3 * @budget)
      assert_receive {:stopped, :revoked}, 10 * @budget
      :atomics.put(context.delays, 2, 0)

      # Defect: the stream is revoked and its owner killed, as every open
      # events stream would be during a slow episode.
      assert_receive {:interrupted, :revoked}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
      assert Lease.check(lease) == {:error, :revoked}
      assert {:ok, %{}} = Trust.lookup(context.store, context.admin.der, DateTime.utc_now())
    end
  end

  defp request(context, protocol, path) do
    {:ok, request} =
      Policy.request(%{
        protocol: protocol,
        method: "GET",
        path: path,
        query: "",
        peer: %{address: {127, 0, 0, 1}, port: 50_000, certificate: context.admin.der}
      })

    request
  end

  defp trust!(state, identities) do
    now = DateTime.utc_now()
    entries = for %{der: der} <- identities, do: Trust.entry(der, "fixture", "", now)
    path = Trust.path(state)
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "certificates" => entries}))
    File.chmod!(path, 0o600)
  end
end
