defmodule Macus.Incus.Coverage do
  @moduledoc """
  The shared client's coverage, read from the locked `:opsmaru_incus`
  package itself (`priv/incus` in the dependency), never from a Macus copy.

  The dependency ships the pinned official Incus reference
  (`reference.json`), the declaration inventory of its `client` and
  `shared/api` packages (`inventory.json`) and a coverage record mapping
  each declaration to an implementation and library test evidence
  (`coverage.json`). Macus only reads them: `gaps/2` lists every
  declaration that is not complete, and `complete_port?/2` is true only
  when the dependency claims a complete port and no gap remains. Evidence
  from the native gateway relay (the library's `test/gateway_*` tests) or
  from Macus's own tests is never typed-client evidence, so it cannot fill
  a gap.

  Go declaration parity (`complete_port?/2`) and behavioural completeness
  (`behavior_errors/3`) are separate claims, as they are in the library.
  Task 6.12 is validated on behaviour: every documented endpoint pair is
  behaviour-complete under a reviewed completion record, every streaming
  contract is certified, and every Incus operation Macus's MCP catalogue
  exposes rests only on library evidence for those rows.

  `docs/incus-coverage.md` is `markdown/0`; regenerate it with
  `mix macus.incus.coverage` after changing the locked dependency.
  """

  alias Opsmaru.Incus.Operations.{Composite, Native}

  @type gap ::
          {String.t(),
           :not_in_coverage
           | :not_in_inventory
           | {:status, String.t()}
           | :no_implementation
           | :no_evidence
           | :relay_or_consumer_evidence_only}

  @doc "The dependency's `priv/incus` directory."
  @spec dir() :: String.t()
  def dir, do: Application.app_dir(:opsmaru_incus, ["priv", "incus"])

  @doc "Decodes one of the dependency's records, such as `\"coverage.json\"`."
  @spec read!(String.t()) :: map()
  def read!(name), do: dir() |> Path.join(name) |> File.read!() |> Jason.decode!()

  @doc "The pinned official Incus reference."
  def reference, do: read!("reference.json")

  @doc "The reference declaration inventory."
  def inventory, do: read!("inventory.json")

  @doc "The dependency's coverage record."
  def coverage, do: read!("coverage.json")

  @doc "The record of fixtures transferred from Macus into the dependency."
  def transfer, do: read!("transfer.json")

  @doc "The dependency's classification of every documented REST endpoint pair."
  def endpoint_inventory, do: read!("endpoint-inventory.json")

  @doc "The dependency's selected evidence for those endpoint pairs."
  def endpoint_evidence, do: read!("endpoint-evidence.json")

  @incus_sources ~w(opsmaru_incus opsmaru_incus_native)

  @doc """
  The records `behavior_errors/3` reads: the pinned reference and the
  endpoint classification and evidence.
  """
  @spec behavior_records() :: map()
  def behavior_records do
    %{
      reference: reference(),
      endpoint_inventory: endpoint_inventory(),
      endpoint_evidence: endpoint_evidence()
    }
  end

  @doc """
  Every Incus operation in Macus's MCP catalogue with the library
  requirements it rests on: a native method (`"GetInstance"`), a helper
  (`"helper:connect"`) or a streaming contract (`"stream:S01"`). Macus's own
  runtime operations are not Incus operations and are left out.
  """
  @spec operation_requirements([map()]) :: [{String.t(), String.t(), [String.t()] | nil}]
  def operation_requirements(operations \\ Macus.MCP.Manifest.operations()) do
    native =
      for {_path, %{"post" => post}} <- Native.openapi()["paths"],
          into: %{},
          do: {post["operationId"], post["x-opsmaru-requires"]}

    for %{source: source, operation_id: id} <- operations, source in @incus_sources do
      requires =
        case source do
          "opsmaru_incus" ->
            case Composite.fetch(id) do
              {:ok, descriptor} -> descriptor.requires
              _ -> nil
            end

          "opsmaru_incus_native" ->
            native[id]
        end

      {id, source, requires}
    end
  end

  @doc """
  Why the locked dependency does not yet back Macus's Incus operations
  behaviourally, or `[]`. Each error is `{subject, reason}`:

    * the endpoint classification is not complete, a documented pair (or
      supplemental server row) is not behaviour-complete under a completion
      record, or a streaming contract is not certified;
    * the selected evidence does not cover every classified pair, or names a
      pair that is not `complete`;
    * a record pins a different Incus reference;
    * an exposed Incus operation names no requirement, a requirement has no
      library evidence (`lookup` is `Opsmaru.Incus.Operations.Evidence.lookup/1`),
      or its only evidence is a relay or Macus test.

  Missing library support is reported here; it is never filled by a Macus
  implementation.
  """
  @spec behavior_errors(map(), list(), (String.t() -> {:ok, map()} | {:error, term()})) ::
          [{String.t(), term()}]
  def behavior_errors(
        records \\ behavior_records(),
        operations \\ operation_requirements(),
        lookup \\ &library_lookup/1
      ) do
    endpoint_errors(records) ++ operation_errors(operations, lookup)
  end

  defp library_lookup(requirement), do: Opsmaru.Incus.Operations.Evidence.lookup(requirement)

  @doc "True when `behavior_errors/3` finds nothing."
  @spec behavior_complete?() :: boolean()
  def behavior_complete?, do: behavior_errors() == []

  defp endpoint_errors(%{reference: reference, endpoint_inventory: inv, endpoint_evidence: ev}) do
    revision = reference["revision"]
    rows = inv["entries"] ++ Map.get(inv, "supplemental_server_entries", [])

    flags =
      for {key, reason} <- [
            {"classification_complete", :classification_incomplete},
            {"behavior_complete", :behavior_incomplete}
          ],
          inv[key] != true,
          do: {"endpoint-inventory.json", reason}

    revisions =
      for {name, record} <- [{"endpoint-inventory.json", inv}, {"endpoint-evidence.json", ev}],
          record["reference_revision"] != revision,
          do: {name, {:reference, record["reference_revision"]}}

    incomplete =
      for row <- rows,
          row["behavior_complete"] != true or not is_binary(row["completion_record"]),
          do: {row["pair"], :behavior_incomplete}

    streams =
      for stream <- Map.get(inv, "stream_contracts", []),
          stream["status"] != "certified" or not is_binary(stream["completion_record"]),
          do: {"stream:" <> to_string(stream["id"]), :stream_not_certified}

    classified = MapSet.new(inv["entries"], & &1["pair"])

    selected =
      MapSet.new(ev["entries"], fn entry ->
        entry["pair"] || "#{entry["verb"]} #{normalize(entry["path"])}"
      end)

    uncovered =
      for pair <- Enum.sort(MapSet.to_list(MapSet.difference(classified, selected))),
          do: {pair, :no_selected_evidence}

    statuses =
      for entry <- ev["entries"],
          entry["status"] != "complete",
          do: {"#{entry["verb"]} #{entry["path"]}", {:evidence_status, entry["status"]}}

    flags ++ revisions ++ incomplete ++ streams ++ uncovered ++ statuses
  end

  # endpoint-evidence.json names path parameters (`{fingerprint}`); the
  # classification's pair keys write them as `{}`.
  defp normalize(path), do: String.replace(path, ~r/\{[^}]*\}/, "{}")

  defp operation_errors(operations, lookup) do
    Enum.flat_map(operations, fn
      {id, _source, requires} when requires in [nil, []] ->
        [{id, :no_requirements}]

      {id, _source, requires} ->
        for requirement <- requires,
            reason = requirement_error(lookup.(requirement)),
            reason != nil,
            do: {id, {requirement, reason}}
    end)
  end

  defp requirement_error({:error, reason}), do: reason

  defp requirement_error({:ok, record}) do
    files = library_files(record)
    if files != [] and Enum.all?(files, &substitute?/1), do: :relay_or_consumer_evidence_only
  end

  defp requirement_error(other), do: {:unexpected, other}

  defp library_files(%{"go" => %{"evidence" => files}}) when is_list(files), do: files

  defp library_files(%{"evidence" => files}) when is_list(files),
    do: Enum.filter(files, &is_binary/1)

  defp library_files(_record), do: []

  @doc """
  Every inventory declaration that is not complete, with the first reason,
  plus coverage entries naming no inventory declaration. Sorted by ID.
  """
  @spec gaps(map(), map()) :: [gap()]
  def gaps(coverage \\ coverage(), inventory \\ inventory()) do
    entries = Map.new(coverage["entries"], &{&1["id"], &1})
    ids = MapSet.new(inventory["entries"], & &1["id"])

    declared =
      for id <- Enum.sort(ids),
          reason = gap(Map.get(entries, id)),
          reason != nil,
          do: {id, reason}

    extra = for id <- Map.keys(entries), id not in ids, do: {id, :not_in_inventory}
    Enum.sort(declared ++ extra)
  end

  defp gap(nil), do: :not_in_coverage
  defp gap(%{"status" => status}) when status != "complete", do: {:status, status}
  defp gap(%{"elixir" => path}) when not is_binary(path) or path == "", do: :no_implementation

  defp gap(%{"evidence" => [_ | _] = evidence}),
    do: if(Enum.all?(evidence, &substitute?/1), do: :relay_or_consumer_evidence_only)

  defp gap(_entry), do: :no_evidence

  @doc """
  True when `path` is evidence that cannot stand for the typed client: a
  native gateway relay test or a Macus consumer test.
  """
  @spec substitute?(String.t()) :: boolean()
  def substitute?(path) when is_binary(path) do
    String.starts_with?(path, ["test/gateway_", "server/", "test/macus/", "test/macus_web/"]) or
      String.contains?(path, "/proxy/")
  end

  def substitute?(_path), do: true

  @doc """
  Whether the dependency is a complete port of the pinned reference: it
  must claim one and leave no gap. A claim alone is not enough.
  """
  @spec complete_port?(map(), map()) :: boolean()
  def complete_port?(coverage \\ coverage(), inventory \\ inventory()),
    do: coverage["complete_port"] == true and gaps(coverage, inventory) == []

  @doc "The coverage summary as Markdown, the content of `docs/incus-coverage.md`."
  @spec markdown() :: String.t()
  def markdown do
    reference = reference()
    inventory = inventory()
    coverage = coverage()
    gaps = gaps(coverage, inventory)
    records = behavior_records()
    operations = operation_requirements()
    behavior = behavior_errors(records, operations)
    statuses = Map.new(coverage["entries"], &{&1["id"], &1["status"]})
    version = Macus.Build.identity().opsmaru_incus.version

    by_kind =
      inventory["entries"]
      |> Enum.group_by(& &1["kind"])
      |> Enum.sort()
      |> Enum.map(fn {kind, entries} ->
        counts = Enum.frequencies_by(entries, &Map.get(statuses, &1["id"], "absent"))

        "| #{kind} | #{length(entries)} | #{counts["complete"] || 0} | #{counts["partial"] || 0} | #{counts["missing"] || 0} |\n"
      end)

    not_started = for {id, {:status, "missing"}} <- gaps, do: "- `#{id}`\n"

    other =
      for {id, reason} <- gaps,
          not match?({:status, s} when s in ["partial", "missing"], reason),
          do: "- `#{id}`: #{inspect(reason)}\n"

    [
      """
      # Shared Incus client coverage

      <!-- Generated by `mix macus.incus.coverage` from the locked opsmaru_incus package. Do not edit. -->

      Macus's typed Incus client is the shared `:opsmaru_incus` library. This
      page records how much of the pinned official Incus Go client it covers,
      read from the locked package's own `priv/incus` records. See
      [the shared Incus client](incus-client.md) for who owns which evidence
      and how to update the dependency.

      | | |
      | --- | --- |
      | Dependency | `opsmaru_incus` #{version} |
      | Reference | `#{reference["module"]}` #{reference["tag"]} (`#{reference["revision"]}`) |
      | Inventory | #{length(inventory["entries"])} declarations from #{length(inventory["sources"])} source files, SHA-256 `#{sha256("inventory.json")}` |
      | Dependency claims a complete port | #{yes(coverage["complete_port"] == true)} |
      | Complete Go declaration port | #{yes(complete_port?(coverage, inventory))} |
      | Declaration gaps | #{length(gaps)} |
      | Behaviourally complete | #{yes(behavior == [])} |

      ## Behavioural completeness

      Macus validates the shared client on behaviour (task 6.12), as the
      library does for its own client: every documented endpoint pair
      behaviour-complete under a reviewed completion record, every streaming
      contract certified, and every Incus operation in Macus's MCP catalogue
      backed only by library evidence for those rows. Go declaration parity,
      below, is a separate claim that this does not make.

      #{behavior_table(records, operations, behavior)}## Go declaration parity

      ### By declaration kind

      | Kind | Declarations | Complete | Partial | Missing |
      | --- | --- | --- | --- | --- |
      """,
      by_kind,
      """

      ### Not implemented

      Declarations the dependency marks `missing`: no implementation and no
      evidence.

      """,
      if(not_started == [], do: "None.\n", else: not_started),
      """

      ### Other gaps

      Declarations missing from the coverage record, coverage entries outside
      the inventory, and complete entries without an implementation or with
      only relay or Macus evidence.

      """,
      if(other == [], do: "None.\n", else: other)
    ]
    |> IO.iodata_to_binary()
  end

  defp behavior_table(records, operations, errors) do
    inv = records.endpoint_inventory
    rows = inv["entries"]
    streams = Map.get(inv, "stream_contracts", [])
    by_source = Enum.frequencies_by(operations, &elem(&1, 1))
    requirements = operations |> Enum.flat_map(&(elem(&1, 2) || [])) |> Enum.uniq()
    failing = errors |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    complete_rows =
      Enum.count(rows, &(&1["behavior_complete"] == true and is_binary(&1["completion_record"])))

    certified = Enum.count(streams, &(&1["status"] == "certified"))
    backed = Enum.count(operations, &(elem(&1, 0) not in failing))

    problems =
      if errors == [],
        do: "None.\n",
        else:
          Enum.map_join(errors, fn {subject, reason} -> "- `#{subject}`: #{inspect(reason)}\n" end)

    """
    | | |
    | --- | --- |
    | Endpoint pairs behaviour-complete | #{complete_rows} of #{length(rows)} |
    | Endpoint classification complete | #{yes(inv["classification_complete"] == true)} |
    | Streaming contracts certified | #{certified} of #{length(streams)} |
    | Incus MCP operations backed by library evidence | #{backed} of #{length(operations)} (#{by_source["opsmaru_incus"] || 0} composite, #{by_source["opsmaru_incus_native"] || 0} native) |
    | Distinct library requirements | #{length(requirements)} |
    | Behaviourally complete | #{yes(errors == [])} |

    ### Problems

    #{problems}
    """
  end

  defp sha256(name),
    do: :crypto.hash(:sha256, File.read!(Path.join(dir(), name))) |> Base.encode16(case: :lower)

  defp yes(true), do: "yes"
  defp yes(false), do: "no"
end
