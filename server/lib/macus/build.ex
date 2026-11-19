defmodule Macus.Build do
  @moduledoc """
  Build identity of this server: the Macus package version, the immutable
  Macus source revision it was built from and the pinned `:opsmaru_incus`
  dependency it bundles.

  The source revision is release build configuration,

      config :macus, Macus.Build, revision: "<40 or 64 lowercase hex>"

  set from `MACUS_SOURCE_REVISION` when the release is built. The
  dependency identity is the version and outer checksum locked in
  `server/mix.lock` when this module was compiled.

  `check/1` is the serving preflight: the build revision must be known and
  equal the revision the launching Swift component expects, and the loaded
  `:opsmaru_incus` must be the locked version. It reads only loaded
  application metadata and opens nothing.

  ## Bundled operation cassette

  The release bundles the opsmaru_incus tama-dex cassette for the locked
  version at `priv/cassettes/opsmaru_incus-<version>.tama-cassette`, and
  records its SHA-256 at build time,

      config :macus, Macus.Build, cassette_sha256: "<64 lowercase hex>"

  set from `MACUS_CASSETTE_SHA256`. `cassette/0` is the import the
  operation index installs from them; nothing is ever downloaded at start.
  """

  @lock Path.expand("../../mix.lock", __DIR__)
  @external_resource @lock

  {locked, _} =
    @lock
    |> File.read!()
    |> Code.string_to_quoted!(emit_warnings: false, file: @lock)
    |> Code.eval_quoted()

  {version, checksum} =
    case Map.fetch(locked, :opsmaru_incus) do
      {:ok, {:hex, :opsmaru_incus, version, _inner, _managers, _deps, _repo, outer}} ->
        {version, outer}

      _ ->
        raise "server/mix.lock does not lock :opsmaru_incus from Hex"
    end

  @opsmaru_incus %{version: version, checksum: checksum}

  @type identity :: %{
          version: String.t(),
          revision: String.t() | nil,
          opsmaru_incus: %{version: String.t(), checksum: String.t()}
        }

  @doc "This build's identity; `revision` is nil when the build recorded none."
  @spec identity() :: identity()
  def identity do
    %{
      version: to_string(Application.spec(:macus, :vsn)),
      revision: revision(),
      opsmaru_incus: @opsmaru_incus
    }
  end

  @doc """
  Checks that this build can serve for a launcher expecting
  `expected_revision`: both revisions must be well-formed and equal, and
  the loaded `:opsmaru_incus` must be the locked version.
  """
  @spec check(String.t() | nil) ::
          :ok | {:error, :missing_revision | :revision_mismatch | :dependency_mismatch}
  def check(expected_revision), do: check(expected_revision, loaded_opsmaru_incus())

  @doc false
  def check(expected_revision, loaded) do
    cond do
      not revision?(revision()) or not revision?(expected_revision) -> {:error, :missing_revision}
      revision() != expected_revision -> {:error, :revision_mismatch}
      loaded != @opsmaru_incus.version -> {:error, :dependency_mismatch}
      true -> :ok
    end
  end

  @doc """
  The release build manifest, written to `macus-build.json` at the release
  root (`Macus.Release.write_manifest/1`) so the Swift component can check
  pairing before it starts this release: schema version 1, this build's
  package `version` and source `revision`, and the bundled `opsmaru_incus`
  version and outer checksum.
  """
  @spec manifest() :: map()
  def manifest do
    identity = identity()

    %{
      "schema_version" => 1,
      "version" => identity.version,
      "revision" => identity.revision,
      "opsmaru_incus" => %{
        "version" => identity.opsmaru_incus.version,
        "checksum" => identity.opsmaru_incus.checksum
      }
    }
  end

  @doc "Whether `value` is a well-formed source revision (40 or 64 lowercase hex)."
  @spec revision?(term()) :: boolean()
  def revision?(value) when is_binary(value),
    do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  def revision?(_), do: false

  @doc """
  The bundled `opsmaru_incus` cassette import for `Macus.Dex.Config`:
  `%{cassette, path, sha256}` for the locked version, or `%{cassette,
  unavailable: :unpinned_bundle}` when the build recorded no valid pin, so
  the index reports that cassette as failed instead of importing an
  unpinned file.
  """
  @spec cassette() ::
          %{cassette: String.t(), path: String.t(), sha256: String.t()}
          | %{cassette: String.t(), unavailable: :unpinned_bundle}
  def cassette do
    pin = Keyword.get(Application.get_env(:macus, __MODULE__, []), :cassette_sha256)

    if is_binary(pin) and Regex.match?(~r/\A[0-9a-f]{64}\z/, pin) do
      %{cassette: "opsmaru_incus", path: cassette_path(), sha256: pin}
    else
      %{cassette: "opsmaru_incus", unavailable: :unpinned_bundle}
    end
  end

  @doc "Where the release bundles the cassette for the locked `:opsmaru_incus` version."
  @spec cassette_path() :: String.t()
  def cassette_path,
    do:
      Application.app_dir(:macus, [
        "priv",
        "cassettes",
        "opsmaru_incus-#{@opsmaru_incus.version}.tama-cassette"
      ])

  defp revision, do: Keyword.get(Application.get_env(:macus, __MODULE__, []), :revision)

  defp loaded_opsmaru_incus do
    case Application.spec(:opsmaru_incus, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end
end
