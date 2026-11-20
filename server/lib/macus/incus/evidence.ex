defmodule Macus.Incus.Evidence do
  @moduledoc """
  The linked evidence of the locked `:opsmaru_incus` package, checked
  independently from Macus's own consumer and proxy reports.

  Macus does not re-run the library's test suite and has no duplicate
  implementation of it. Instead it links the evidence the package ships
  under `priv/incus` and verifies, for the locked dependency:

  * **Exact revisions.** The Hex version and checksum in `mix.lock`
    (`Macus.Build.identity/0`), the loaded package's own version and source,
    and the Incus reference revision recorded in every evidence record all
    agree. A mismatch, a missing record or an unknown reference fails.
  * **Library conformance linked, not rerun.** Every shipped record is
    present, decodable, hash-consistent with the package's own
    `transfer.json`, and self-consistent: the inventory's reference block
    equals `reference.json`, coverage entries stay inside the inventory,
    complete entries name implementation files the package actually ships,
    and a complete claim backed only by relay or consumer evidence is a
    failure, per `Macus.Incus.Coverage.gaps/2`.
  * **Shared-client coverage linked.** Every Macus consumer binding maps to
    a library requirement with recorded evidence
    (`Opsmaru.Incus.Operations.Evidence`), every operation Macus exposes
    through MCP `search`/`execute` is a library operation the library does
    not mark unavailable, and every `Opsmaru.Incus` function Macus's own
    code actually calls is covered by a binding entry (`call_errors/0`);
    an entry never lists an MFA that no Macus code calls.
  * **No evidence class replaces another.** `classify/1` and
    `countable_as?/2` keep the four evidence classes distinct: library
    evidence, Macus consumer/binding tests, proxy/relay fixtures, and
    hardware acceptance, which nothing in this check ever claims.

  `docs/incus-evidence.md` is `markdown/0`; regenerate it with
  `mix macus.incus.evidence` after changing the locked dependency.
  """

  alias Macus.Incus.Coverage
  alias Opsmaru.Incus.Operations.{Composite, Native}
  alias Opsmaru.Incus.Operations.Evidence, as: OperationEvidence

  @files ~w(
    reference.json
    inventory.json
    coverage.json
    endpoint-inventory.json
    endpoint-evidence.json
    methods.json
    models.json
    constants.json
    native-operations.json
    native-policy.json
    transfer.json
    gateway-transfer.json
  )

  # The bindings Macus's code makes into the shared library, each mapped to
  # the library requirement whose evidence backs it. A requirement is a
  # ledger key (checked against `Opsmaru.Incus.Operations.Evidence`), or
  # `:relay` / `:operations`, the evidence class the binding belongs to
  # (the gateway-transfer record, or the operation documents and the
  # endpoint-inventory ledger). Each entry also records the library MFAs
  # Macus's compiled code calls under that binding; `call_errors/0`
  # cross-checks them against the calls the code actually makes, in both
  # directions. Bindings exercised only by consumer tests carry no
  # production MFA; the evidence they resolve to is read from the package
  # at check time, never copied here.
  @bindings [
    {
      "owner's incus.sock connection and trusted host context (Macus.MCP.IncusHost.client/1, Macus.Proxy.Host)",
      "helper:connect",
      [
        {Opsmaru.Incus, :connect, 2},
        {Opsmaru.Incus.Connection, :unix!, 2},
        {Opsmaru.Incus.Context, :new!, 1}
      ]
    },
    {
      "client workers (Macus.Incus.run/3)",
      "helper:connect",
      [
        {Opsmaru.Incus.ClientSupervisor, :child_spec, 1},
        {Opsmaru.Incus.ClientSupervisor, :async, 2}
      ]
    },
    {"MCP operation search (Macus.MCP.IncusHost.search/1)", "GetInstance",
     [{Opsmaru.Incus.Operations.Composite, :fetch, 1}]},
    {"MCP operation execute, composite (Macus.Dex.IncusExecutor)", "GetInstance",
     [{Opsmaru.Incus.Operations.Composite, :run, 3}]},
    {"MCP operation execute, native (Macus.Dex.NativeExecutor)", :operations,
     [{Opsmaru.Incus.Operations.Native, :run, 3}]},
    {"MCP operation catalogue (Macus.MCP.Manifest)", :operations,
     [
       {Opsmaru.Incus.Operations.Composite, :openapi, 0},
       {Opsmaru.Incus.Operations.Native, :openapi, 0}
     ]},
    {"linked-evidence introspection (Macus.Incus.Evidence)", :operations,
     [
       {Opsmaru.Incus.Operations.Composite, :all, 0},
       {Opsmaru.Incus.Operations.Composite, :unavailable, 0},
       {Opsmaru.Incus.Operations.Native, :unavailable, 0},
       {Opsmaru.Incus.Operations.Evidence, :lookup, 1}
     ]},
    {"endpoint-inventory diff (Mix.Tasks.Macus.Incus.Coverage)", :operations,
     [{Opsmaru.Incus.Inventory, :diff, 2}]},
    {"private gateway relay (Macus.Proxy, Macus.Proxy.Host, MacusWeb.Router)", :relay,
     [
       {Opsmaru.Incus, :raw_query, 5},
       {Opsmaru.Incus.Connection, :project, 2},
       {Opsmaru.Incus.Gateway, :new!, 1},
       {Opsmaru.Incus.Gateway.Plug, :init, 0}
     ]},
    {"server information, readiness and extension checks (Opsmaru.Incus.has_extension?/2)",
     "helper:connect", []},
    {"typed method calls with member selection (Opsmaru.Incus.call/4)", "GetInstance", []},
    {"instance file reads (Opsmaru.Incus.Files.read/4)", "helper:read", []},
    {"instance file creates (Opsmaru.Incus.Files.create/5)", "helper:create", []},
    {"instance backup downloads (Opsmaru.Incus.Files.backup_download/4)",
     "helper:backup_download", []},
    {"image export byte streams (Opsmaru.Incus.Transfer.download/3)", "helper:download", []},
    {"image import byte streams (Opsmaru.Incus.Transfer.upload/4)", "stream:S05", []},
    {"event subscriptions (Opsmaru.Incus.Events)", "stream:S03", []},
    {"console sessions (Opsmaru.Incus.Session)", "stream:S02", []},
    {"NBD raw channels (Opsmaru.Incus.nbd/2 and Opsmaru.Incus.RawChannel)", "helper:nbd", []}
  ]

  @type record_set :: %{String.t() => {:ok, map()} | {:error, term()}}

  @doc "The evidence record names shipped under the dependency's `priv/incus`."
  @spec files() :: [String.t()]
  def files, do: @files

  @doc """
  Decodes one evidence record of the locked package. Returns `{:ok, map}` or
  `{:error, reason}` when the file is missing or not valid JSON.
  """
  @spec record(String.t()) :: {:ok, map()} | {:error, term()}
  def record(name) do
    with {:ok, raw} <- File.read(Path.join(Coverage.dir(), name)),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, decoded}
    end
  end

  @doc "Every evidence record of the locked package, as a record set."
  @spec records() :: record_set()
  def records do
    for name <- files(), into: %{}, do: {name, record(name)}
  end

  @doc """
  The Incus reference revision a record pins, or `nil` for records that pin
  something else: `gateway-transfer.json` pins Macus's source revision and
  `native-operations.json` is pinned by `native-policy.json`'s upstream.
  """
  @spec revision_in(String.t(), map()) :: String.t() | nil
  def revision_in("reference.json", record), do: record["revision"]
  def revision_in("inventory.json", record), do: record["reference"]["revision"]
  def revision_in("native-policy.json", record), do: record["upstream"]["revision"]

  def revision_in(name, record)
      when name in ~w(
             coverage.json
             endpoint-inventory.json
             endpoint-evidence.json
             methods.json
             models.json
             constants.json
             transfer.json
           ),
      do: record["reference_revision"]

  def revision_in(_name, _record), do: nil

  @doc """
  Verifies that every record pins the same well-formed reference revision as
  `reference.json`. Fails on a missing record, a malformed reference, or any
  record that pins a different or unknown revision.
  """
  @spec revisions(record_set()) :: {:ok, map()} | {:error, [String.t()]}
  def revisions(records) do
    {reference, reference_errors} =
      case Map.get(records, "reference.json") do
        {:ok, reference} ->
          {reference, reference |> revision_errors()}

        _ ->
          {nil, ["reference.json is missing or unreadable"]}
      end

    missing =
      for {name, {:error, reason}} <- records,
          into: [],
          do: "evidence record #{name} is missing or unreadable: #{inspect(reason)}"

    unknown =
      for {name, {:ok, record}} <- records,
          pinned = revision_in(name, record),
          is_binary(pinned),
          not is_revision(pinned),
          do: "evidence record #{name} pins an unknown reference revision #{inspect(pinned)}"

    mismatched =
      for {name, {:ok, record}} <- records,
          pinned = revision_in(name, record),
          is_binary(pinned),
          is_revision(pinned),
          not is_nil(reference),
          is_revision(reference["revision"]),
          pinned != reference["revision"],
          do: "evidence record #{name} pins #{pinned}, not #{reference["revision"]}"

    errors = missing ++ reference_errors ++ unknown ++ mismatched
    if errors == [], do: {:ok, reference}, else: {:error, Enum.sort(errors)}
  end

  defp revision_errors(reference) do
    fields = [
      {"repository", reference["repository"]},
      {"tag", reference["tag"]},
      {"revision", reference["revision"]},
      {"module", reference["module"]}
    ]

    fields
    |> Enum.flat_map(fn {field, value} ->
      if is_binary(value) and value != "", do: [], else: ["reference.json has no #{field}"]
    end)
    |> then(fn errors ->
      case reference["revision"] do
        revision when is_binary(revision) ->
          if is_revision(revision),
            do: errors,
            else: [
              "reference.json has an unknown reference revision #{inspect(revision)}" | errors
            ]

        _ ->
          errors
      end
    end)
  end

  defp is_revision(revision), do: is_binary(revision) and revision =~ ~r/\A[0-9a-f]{40}\z/

  @doc "The locked dependency: version and outer Hex checksum from `server/mix.lock`."
  @spec locked() :: %{version: String.t(), checksum: String.t()}
  def locked, do: Macus.Build.identity().opsmaru_incus

  @doc """
  The loaded dependency's own metadata: its version, the source URL its
  `mix.exs` declares, and the versions its operation documents carry.
  """
  @spec loaded() :: %{version: String.t(), source_url: String.t() | nil, doc_versions: map()}
  def loaded do
    source_url =
      case File.read(Path.join(dep_root(), "mix.exs")) do
        {:ok, contents} ->
          case Regex.run(~r/@source_url\s+"([^"]+)"/, contents) do
            [_, url] -> url
            nil -> nil
          end

        _ ->
          nil
      end

    %{
      version: to_string(Application.spec(:opsmaru_incus, :vsn)),
      source_url: source_url,
      doc_versions: %{
        composite: Composite.openapi()["info"]["version"],
        native: Native.openapi()["info"]["version"]
      }
    }
  end

  @doc """
  Verifies the loaded package is exactly the locked one: the locked Hex
  version equals the loaded version and both operation documents' versions.
  """
  @spec library_errors(%{locked: map(), loaded: map()}) :: [String.t()]
  def library_errors(%{locked: locked, loaded: loaded}) do
    version_errors =
      if locked.version != loaded.version do
        ["the loaded opsmaru_incus is #{loaded.version}, but mix.lock locks #{locked.version}"]
      else
        []
      end

    document_errors =
      for {name, version} <- loaded.doc_versions,
          version != locked.version,
          do: "the #{name} operation document is version #{version}, not #{locked.version}"

    Enum.sort(version_errors ++ document_errors)
  end

  @doc """
  Verifies every `priv` file the package's `transfer.json` records is byte
  for byte what the record hashes. Returns `{:ok, count}` or the errors.
  """
  @spec integrity(record_set()) :: {:ok, pos_integer()} | {:error, [String.t()]}
  def integrity(records) do
    case Map.get(records, "transfer.json") do
      {:ok, transfer} ->
        integrity_with(transfer)

      other ->
        {:error, ["transfer.json has no recorded files: #{inspect(other)}"]}
    end
  end

  defp integrity_with(transfer) do
    case transfer["files"] do
      files when is_list(files) ->
        # The priv/incus records are the linked evidence and must be byte for
        # byte what the record hashes. The priv/notices files are provenance
        # the package maintains, so they only have to ship.
        records = for %{"destination" => "priv/incus/" <> _} = file <- files, do: file
        notices = for %{"destination" => "priv/notices/" <> _} = file <- files, do: file

        errors =
          for file <- records do
            case sha256(Path.join(Application.app_dir(:opsmaru_incus), file["destination"])) do
              nil ->
                "evidence record #{file["destination"]} is missing from the package"

              digest ->
                if digest != file["transferred_sha256"],
                  do:
                    "evidence record #{file["destination"]} no longer hashes to " <>
                      "#{file["transferred_sha256"]} recorded in transfer.json",
                  else: nil
            end
          end
          |> Enum.reject(&is_nil/1)
          |> then(fn errors ->
            errors ++
              for file <- notices,
                  not File.exists?(
                    Path.join(Application.app_dir(:opsmaru_incus), file["destination"])
                  ),
                  do: "notice #{file["destination"]} is missing from the package"
          end)

        if errors == [], do: {:ok, length(records)}, else: {:error, errors}

      other ->
        {:error, ["transfer.json has no recorded files: #{inspect(other)}"]}
    end
  end

  @doc """
  Verifies the library-owned records are well formed and self-consistent for
  the pinned reference. Partial-port gaps are not errors here; they are the
  coverage page's. Errors are coverage entries outside the inventory,
  complete claims backed only by relay or consumer evidence, implementations
  the package does not ship, and records that disagree with each other.
  """
  @spec well_formed_errors(record_set()) :: [String.t()]
  def well_formed_errors(records) do
    case {Map.get(records, "reference.json"), Map.get(records, "inventory.json"),
          Map.get(records, "coverage.json")} do
      {{:ok, reference}, {:ok, inventory}, {:ok, coverage}} ->
        reference_errors =
          if inventory["reference"] == reference do
            []
          else
            ["inventory.json's reference block no longer equals reference.json"]
          end

        gaps =
          Coverage.gaps(coverage, inventory)
          |> Enum.filter(fn {_id, reason} ->
            reason in [:not_in_inventory, :relay_or_consumer_evidence_only]
          end)

        gap_errors =
          for {id, reason} <- gaps,
              do: gap_error(id, reason)

        implementation_errors =
          for entry <- coverage["entries"],
              is_binary(entry["elixir"]) and entry["elixir"] != "",
              not File.exists?(Path.join(dep_root(), entry["elixir"])),
              do:
                "coverage entry #{entry["id"]} names #{entry["elixir"]}, " <>
                  "which the package does not ship"

        endpoint_errors =
          with {:ok, %{"source" => source}} <- Map.get(records, "endpoint-evidence.json"),
               {:ok, %{"source" => inventory_source}} <-
                 Map.get(records, "endpoint-inventory.json") do
            if source == inventory_source,
              do: [],
              else: ["endpoint-evidence.json and endpoint-inventory.json pin different sources"]
          else
            _ -> []
          end

        reference_errors ++ gap_errors ++ implementation_errors ++ endpoint_errors

      _ ->
        ["the reference, inventory or coverage record is missing; see the record errors"]
    end
  end

  defp gap_error(id, :not_in_inventory),
    do: "coverage entry #{id} names no declaration of the pinned inventory"

  defp gap_error(id, :relay_or_consumer_evidence_only),
    do: "coverage entry #{id} claims complete but only relay or consumer evidence backs it"

  @doc """
  The Macus consumer bindings and the library requirement each one depends
  on, in declaration order, with the library MFAs Macus's own code calls
  under each binding.
  """
  @spec bindings() :: [{String.t(), String.t() | :relay | :operations, [tuple()]}]
  def bindings, do: @bindings

  @doc """
  The calls Macus's compiled code makes into the shared library.

  Reads every BEAM file under `ebin` and the calls out of the compiler
  IR in its `debug_info` chunk, so aliases, imports, pipes and
  multi-line calls all resolve exactly as the code runs: the IR holds
  fully qualified module references, and a function reference that is
  never called does not count. Only the macus app's own compiled
  modules are scanned, so dependency code never counts. Returns
  `%{callee_mfa => [caller modules]}`.
  """
  @spec called_mfas(String.t() | nil) :: %{tuple() => [atom()]}
  def called_mfas(ebin \\ nil) do
    dir = ebin || Application.app_dir(:macus, "ebin")

    for path <- Path.wildcard(Path.join(dir, "*.beam")) do
      charlist = String.to_charlist(path)
      {:ok, {_bin, chunks}} = :beam_lib.chunks(charlist, [:debug_info])
      caller = to_atom(:beam_lib.info(charlist)[:module])
      info = elem(elem(chunks[:debug_info], 2), 1)

      for {mod, fun, arity} <- remote_calls(info),
          String.starts_with?(to_string(mod), "Elixir.Opsmaru.Incus") do
        {{mod, fun, arity}, caller}
      end
    end
    |> List.flatten()
    |> Enum.group_by(fn {mfa, _caller} -> mfa end, fn {_mfa, caller} -> caller end)
    |> Map.new(fn {mfa, callers} -> {mfa, Enum.sort(Enum.uniq(callers))} end)
  end

  @doc """
  Cross-checks the bindings against the calls Macus's compiled code makes.

  Fails when Macus code calls a library function no binding entry covers
  (naming the caller and the MFA), and when an entry lists an MFA no
  Macus code calls. `calls_dir` selects the ebin to read; the default is
  the running app's ebin, which under the test environment includes the
  consumer tests.
  """
  @spec call_errors(String.t() | nil) :: [String.t()]
  def call_errors(calls_dir \\ nil) do
    call_error_list(called_mfas(calls_dir), bindings())
  end

  @doc "The call cross-check against an explicit call set and binding list."
  @spec call_error_list(%{tuple() => [atom()]}, [{String.t(), term(), [tuple()]}]) :: [String.t()]
  def call_error_list(calls, bindings) do
    declared = for binding <- bindings, mfa <- elem(binding, 2), do: mfa

    uncovered =
      for {mfa, callers} <- calls,
          mfa not in declared do
        "#{Enum.join(Enum.map(callers, &Macro.to_string/1), ", ")} calls " <>
          "#{mfa_name(mfa)}, which no shared-client binding entry covers"
      end

    stale =
      for binding <- bindings,
          mfa <- elem(binding, 2),
          mfa not in Map.keys(calls) do
        "binding \"#{elem(binding, 0)}\" lists #{mfa_name(mfa)}, which no Macus code calls"
      end

    uncovered ++ stale
  end

  @doc """
  The bindings with no library evidence: ledger requirements the library
  does not resolve. Entries whose requirement is `:relay` or `:operations`
  belong to another evidence class whose records the check verifies
  separately. An empty list means every binding is linked.
  """
  @spec binding_errors([{String.t(), String.t() | :relay | :operations, [tuple()]}]) :: [
          String.t()
        ]
  def binding_errors(bindings) do
    for {label, requirement, _} <- bindings,
        is_binary(requirement) do
      case OperationEvidence.lookup(requirement) do
        {:error, reason} ->
          "no library evidence for the #{label} binding: #{requirement} (#{inspect(reason)})"

        {:ok, _} ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Verifies every operation Macus exposes through MCP `search`/`execute` is a
  library operation, and none is one the library marks unavailable.
  """
  @spec operations_errors([Macus.MCP.Manifest.operation()]) :: [String.t()]
  def operations_errors(operations \\ Macus.MCP.Manifest.operations()) do
    composite = Enum.map(Composite.all(), & &1.name)
    composite_unavailable = Enum.map(Composite.unavailable(), & &1["name"])

    native =
      Native.openapi()["paths"]
      |> Map.values()
      |> Enum.map(& &1["post"]["operationId"])

    native_unavailable = Enum.map(Native.unavailable(), & &1["name"])

    for operation <- operations,
        {available, unavailable, source} =
          source_of(operation, composite, composite_unavailable, native, native_unavailable),
        not is_nil(available) do
      cond do
        operation.operation_id in unavailable ->
          "#{operation.operation_id} is exposed by Macus but the #{source} " <>
            "library marks it unavailable"

        operation.operation_id not in available ->
          "#{operation.operation_id} is exposed by Macus but no #{source} " <>
            "library operation has it"

        true ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp source_of(operation, composite, composite_unavailable, native, native_unavailable) do
    case operation.source do
      "opsmaru_incus" -> {composite, composite_unavailable, "composite"}
      "opsmaru_incus_native" -> {native, native_unavailable, "native"}
      _ -> {nil, nil, nil}
    end
  end

  @doc "The operations the library marks unavailable, tagged by source."
  @spec unavailable() :: [map()]
  def unavailable do
    Enum.map(Composite.unavailable(), &Map.put(&1, "source", "opsmaru_incus")) ++
      Enum.map(Native.unavailable(), &Map.put(&1, "source", "opsmaru_incus_native"))
  end

  @typedoc "An evidence class: library, Macus consumer, proxy/relay, or hardware acceptance."
  @type class :: :library | :consumer | :relay | :hardware

  @doc """
  Classifies an evidence path by the class it belongs to. Relay paths are the
  library's `test/gateway_*` fixtures and anything under a `proxy`
  directory; consumer paths are Macus's own tests, the set
  `Macus.Incus.Coverage.substitute?/1` keeps out of typed-client evidence;
  hardware paths are the acceptance transcripts; everything else is library
  evidence of the locked package.
  """
  @spec classify(String.t()) :: class()
  def classify(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "test/gateway_") or String.contains?(path, "/proxy/") or
          String.ends_with?(path, "reference_wire_test.exs") ->
        :relay

      Coverage.substitute?(path) ->
        :consumer

      String.starts_with?(path, "docs/testing/") and
          String.contains?(Path.basename(path), "acceptance") ->
        :hardware

      true ->
        :library
    end
  end

  @doc """
  True only when `path` is evidence of exactly `class`: evidence of another
  class never counts as this one.
  """
  @spec countable_as?(class(), String.t()) :: boolean()
  def countable_as?(class, path) when is_binary(path), do: classify(path) == class

  @doc """
  Runs the whole check against the locked package and returns the summary,
  with errors when any part of the link fails. Hardware acceptance is never
  claimed by this check: it is a separate, opt-in class.
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, map()}
  def check(opts \\ []) do
    records = records()
    library = %{locked: locked(), loaded: loaded()}

    {integrity_files, integrity_errors} =
      case integrity(records) do
        {:ok, count} -> {count, []}
        {:error, errors} -> {0, errors}
      end

    {reference, revision_errors} =
      case revisions(records) do
        {:ok, reference} -> {reference, []}
        {:error, errors} -> {nil, errors}
      end

    errors =
      Enum.sort(
        revision_errors ++
          library_errors(library) ++
          integrity_errors ++
          well_formed_errors(records) ++
          binding_errors(bindings()) ++
          call_errors(opts[:calls_dir]) ++
          operations_errors()
      )

    summary = %{
      errors: errors,
      reference: reference,
      locked: library.locked,
      loaded: library.loaded,
      records: map_size(records),
      integrity_files: integrity_files,
      gaps: length(Coverage.gaps()),
      complete_port: Coverage.complete_port?(),
      bindings: Enum.count(bindings()),
      covered_calls: called_mfas(opts[:calls_dir]) |> Map.keys() |> length(),
      unavailable: unavailable(),
      hardware: "none claimed; a separate, opt-in class"
    }

    if errors == [], do: {:ok, summary}, else: {:error, summary}
  end

  @doc "The linked-evidence summary as Markdown, the content of `docs/incus-evidence.md`."
  @spec markdown(keyword()) :: String.t()
  def markdown(opts \\ []) do
    {:ok, summary} = check(opts)
    %{reference: reference, locked: locked, loaded: loaded} = summary

    source_line =
      if is_nil(loaded.source_url) do
        []
      else
        ["| Package source | #{loaded.source_url} |\n"]
      end

    reference_line =
      if is_nil(reference) do
        "| Reference | unavailable |\n"
      else
        "| Reference | `#{reference["module"]}` #{reference["tag"]} (`#{reference["revision"]}`) |\n"
      end

    [
      """
      # Linked Incus evidence

      <!-- Generated by `mix macus.incus.evidence` from the locked opsmaru_incus package. Do not edit. -->

      The shared client Macus links is the `:opsmaru_incus` package. This
      page records that the evidence the package ships is exactly the locked
      package's, is well formed and self-consistent for the pinned reference,
      and is linked to Macus's consumer bindings, independently from Macus's
      own consumer and proxy reports. See [the shared Incus client](incus-client.md)
      for who owns which evidence and [coverage](incus-coverage.md) for how
      much of the reference the library covers.

      | | |
      | --- | --- |
      | Dependency | `opsmaru_incus` #{locked.version} |
      | Hex outer checksum (`server/mix.lock`) | `#{locked.checksum}` |
      | Package version (loaded) | #{loaded.version} |
      """,
      source_line,
      reference_line,
      """
      | Evidence records | #{summary.records} files under the package's `priv/incus`; every one that pins the Incus reference agrees with `reference.json` |
      | Record integrity | #{summary.integrity_files} `priv` files hash to the package's `transfer.json` records |
      | Complete port | #{yes(summary.complete_port)} (a claim alone is never enough; see the coverage page) |
      | Hardware acceptance | #{summary.hardware} |

      ## Evidence classes

      Four classes of evidence, kept distinct by `Macus.Incus.Evidence` and
      `Macus.Incus.Coverage.substitute?/1`; one class never counts as
      another, and substituting one for another fails the check.

      | Class | What it is | Where it lives |
      | --- | --- | --- |
      | Library | Client, gateway and operation evidence the package ships, at the locked reference | `priv/incus/*.json` in the locked package |
      | Consumer | Macus's binding tests over its own `incus.sock` | `server/test/macus/incus/`, `server/test/macus/mcp/`, `server/test/macus_web/` |
      | Relay | Native gateway relay fixtures, through the Macus listener with the official client | `server/test/macus/proxy/`, `server/test/macus/incus/reference_wire_test.exs`, the library's `test/gateway_*` |
      | Hardware | Real guest workloads through an installed Macus | [Acceptance](acceptance.md); opt-in transcripts under `docs/testing/` |

      ## Linked bindings

      Every binding Macus's code makes into the shared library, the library
      requirement or evidence class whose evidence backs it, and the
      library MFAs Macus's compiled code calls under it. The call set is
      read out of the compiled modules, so aliases, imports, pipes and
      multi-line calls all count: every one of the `#{summary.covered_calls}`
      calls is covered by exactly one entry, an entry never lists an MFA no
      Macus code calls, and a binding with no library evidence fails
      `mix macus.incus.evidence --check`.

      | Macus binding | Library evidence | Library MFAs Macus's code calls |
      | --- | --- | --- |
      """,
      Enum.map_join(bindings(), fn {label, requirement, mfas} ->
        mfas =
          if mfas == [],
            do: "_consumer tests only_",
            else:
              Enum.map_join(
                Enum.sort_by(mfas, &mfa_name/1),
                ", ",
                fn mfa -> "`" <> mfa_name(mfa) <> "`" end
              )

        "| #{label} | #{requirement_text(requirement)} | #{mfas} |\n"
      end),
      """
      ## Library operations Macus does not expose

      Operations the library marks unavailable; Macus's MCP catalogue never
      lists them, and exposing one fails the check.

      | Operation | Source | Reason |
      | --- | --- | --- |
      """,
      Enum.map_join(summary.unavailable, fn %{
                                              "name" => name,
                                              "source" => source,
                                              "reason" => reason
                                            } ->
        "| `#{name}` | #{source} | #{reason} |\n"
      end)
    ]
    |> IO.iodata_to_binary()
  end

  # The dependency's source root; implementation files ship there, while the
  # evidence records are read from the application directory at runtime.
  defp dep_root, do: Path.expand("../../../deps/opsmaru_incus", __DIR__)

  defp sha256(path) do
    with {:ok, bytes} <- File.read(path),
         do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp yes(true), do: "yes"
  defp yes(false), do: "no"

  defp requirement_text(requirement) when is_binary(requirement), do: "`#{requirement}`"

  defp requirement_text(:relay) do
    "relay class; the gateway-transfer record"
  end

  defp requirement_text(:operations) do
    "operation documents and the endpoint-inventory ledger"
  end

  defp mfa_name({module, function, arity}) do
    "#{Macro.to_string(module)}.#{function}/#{arity}"
  end

  defp to_atom(name), do: String.to_atom(to_string(name))

  # A remote call in the compiler IR is a three-tuple whose head is
  # `{:., _attrs, [Module, :fun]}`; anything else is walked for nested
  # calls. Function references, which wrap the same head in
  # `{:function, _}` / `:{^, _}` terms, never match the call shape.
  defp remote_calls({{:., _attrs, [mod, fun]}, _call_attrs, args})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    [{mod, fun, length(args)}] ++ Enum.flat_map(args, &remote_calls/1)
  end

  defp remote_calls(term) when is_tuple(term) do
    Enum.flat_map(Tuple.to_list(term), &remote_calls/1)
  end

  defp remote_calls(term) when is_list(term) do
    Enum.flat_map(term, &remote_calls/1)
  end

  defp remote_calls(term) when is_map(term) do
    Enum.flat_map(term, fn {_key, value} -> remote_calls(value) end)
  end

  defp remote_calls(_term), do: []
end
