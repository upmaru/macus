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

  defp revision, do: Keyword.get(Application.get_env(:macus, __MODULE__, []), :revision)

  defp revision?(value) when is_binary(value),
    do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  defp revision?(_value), do: false

  defp loaded_opsmaru_incus do
    case Application.spec(:opsmaru_incus, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end
end
