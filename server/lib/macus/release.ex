defmodule Macus.Release do
  @moduledoc """
  Release build steps.

  `write_manifest/1` runs after `:assemble`. It first verifies the assembled
  release (`verify/2`) and then writes `macus-build.json`
  (`Macus.Build.manifest/1`, mode 0444) at the release root, beside `bin/`,
  `lib/`, `releases/` and the bundled `erts-*`. `macus start` reads it before
  it starts this release and refuses a release whose revision or version
  differs from the Swift executable's, or whose recorded `opsmaru_incus` is
  not the one under `lib/`.

  The release must be complete and self-contained for macOS ARM64, or
  nothing is recorded and the build fails:

    * the build runs on `aarch64-apple-darwin`, and exactly one bundled
      `erts-*` holds an ARM64 `bin/beam.smp`, so no host Erlang is used;
    * a valid source revision (`MACUS_SOURCE_REVISION`) was recorded;
    * `lib/` holds exactly the locked `opsmaru_incus` and `tama_dex`;
    * the opsmaru_incus cassette for the locked version is the only file in
      `macus`'s `priv/cassettes/`, and its SHA-256 equals the pin recorded
      at build time (`MACUS_CASSETTE_SHA256`);
    * the locked `exqlite`'s `priv/sqlite3_nif.so`, the NIF `tama_dex`
      loads, is an ARM64 Mach-O. Its precompiled build is verified by
      exqlite's own checksums, which the locked package checksum covers;
    * `releases/<vsn>/env.sh` turns Erlang distribution off
      (`rel/env.sh.eex`).
  """

  @manifest "macus-build.json"
  @distribution "export RELEASE_DISTRIBUTION=none"
  @target "aarch64-apple-darwin"

  @doc "The manifest's file name at the release root."
  def manifest_name, do: @manifest

  @doc "The line `env.sh` must carry to keep distribution off."
  def distribution_line, do: @distribution

  @doc """
  Release step, after `:assemble` and before `write_manifest/1`: bundles
  the cassette at `MACUS_CASSETTE_PATH`, when that is set, as the only file
  in `macus`'s `priv/cassettes/`, replacing whatever the assembly copied
  from `server/priv/cassettes`. The file must be a regular file named for
  the locked version (`Macus.Build.cassette_file/0`), so a cassette for
  another `opsmaru_incus` version fails the build. Unset, the assembled
  cassette stays and `write_manifest/1` checks it. `:source` overrides the
  environment (for tests).
  """
  @spec bundle_cassette(Mix.Release.t() | map(), keyword()) :: Mix.Release.t() | map()
  def bundle_cassette(%{path: path} = release, opts \\ []) do
    case Keyword.get_lazy(opts, :source, fn -> System.get_env("MACUS_CASSETTE_PATH") end) do
      source when source in [nil, ""] ->
        release

      source ->
        file = Macus.Build.cassette_file()

        unless Path.basename(source) == file and
                 match?({:ok, %File.Stat{type: :regular}}, File.lstat(source)),
               do:
                 Mix.raise("MACUS_CASSETTE_PATH must name a regular file #{file}, not #{source}")

        {:ok, [app]} = matching(Path.join(path, "lib"), "macus-")
        dir = Path.join([path, "lib", app, "priv", "cassettes"])
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        File.cp!(source, Path.join(dir, file))
        release
    end
  end

  @doc "Release step: verifies the release, then writes the build manifest (0444)."
  @spec write_manifest(Mix.Release.t() | map(), keyword()) :: Mix.Release.t() | map()
  def write_manifest(%{path: path} = release, opts \\ []) do
    case verify(path, opts) do
      {:ok, bundle} ->
        file = Path.join(path, @manifest)
        File.rm(file)
        document = Jason.encode_to_iodata!(Macus.Build.manifest(bundle), pretty: true)
        File.write!(file, [document, ?\n])
        File.chmod!(file, 0o444)
        release

      {:error, message} ->
        Mix.raise("The Macus release is incomplete: " <> message)
    end
  end

  @doc """
  Verifies the assembled release at `path`. Returns what the manifest
  records, or `{:error, message}`. `:architecture` overrides the build
  host's `system_architecture` (for tests).
  """
  @spec verify(String.t(), keyword()) ::
          {:ok,
           %{
             cassette_sha256: String.t(),
             nif_sha256: String.t(),
             erts: String.t(),
             target: String.t()
           }}
          | {:error, String.t()}
  def verify(path, opts \\ []) do
    architecture =
      Keyword.get_lazy(opts, :architecture, fn ->
        to_string(:erlang.system_info(:system_architecture))
      end)

    with :ok <- target(architecture),
         :ok <- revision(),
         {:ok, erts} <- erts(path),
         :ok <- library(path, :opsmaru_incus),
         :ok <- library(path, :tama_dex),
         {:ok, cassette} <- cassette(path),
         {:ok, nif} <- nif(path),
         :ok <- distribution(path) do
      {:ok, %{cassette_sha256: cassette, nif_sha256: nif, erts: erts, target: @target}}
    end
  end

  defp target(architecture) do
    if String.starts_with?(architecture, @target),
      do: :ok,
      else: {:error, "it must be built on #{@target}, not #{architecture}"}
  end

  defp revision do
    if Macus.Build.revision?(Macus.Build.identity().revision),
      do: :ok,
      else: {:error, "it needs MACUS_SOURCE_REVISION (40 or 64 lowercase hex) at build time"}
  end

  defp erts(path) do
    with {:ok, [dir]} <- matching(path, "erts-"),
         :ok <- arm64(Path.join([path, dir, "bin", "beam.smp"]), "the bundled ERTS") do
      {:ok, String.replace_prefix(dir, "erts-", "")}
    else
      {:ok, _} -> {:error, "it must bundle exactly one ERTS"}
      error -> error
    end
  end

  defp library(path, name) do
    %{version: version} = Macus.Build.locked(name)
    expected = "#{name}-#{version}"

    case matching(Path.join(path, "lib"), "#{name}-") do
      {:ok, [^expected]} -> :ok
      _ -> {:error, "lib/ must hold exactly #{name} #{version}, the locked version"}
    end
  end

  defp cassette(path) do
    file = Macus.Build.cassette_file()

    with {:ok, pin} <- pin(),
         {:ok, [app]} <- matching(Path.join(path, "lib"), "macus-"),
         dir = Path.join([path, "lib", app, "priv", "cassettes"]),
         {:ok, [^file]} <- File.ls(dir),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(Path.join(dir, file)),
         ^pin <- sha256(Path.join(dir, file)) do
      {:ok, pin}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "priv/cassettes must hold only #{file}, matching MACUS_CASSETTE_SHA256"}
    end
  end

  defp pin do
    case Macus.Build.cassette_pin() do
      nil -> {:error, "it needs MACUS_CASSETTE_SHA256 (64 lowercase hex) at build time"}
      pin -> {:ok, pin}
    end
  end

  defp nif(path) do
    %{version: version} = Macus.Build.locked(:exqlite)
    file = Path.join([path, "lib", "exqlite-#{version}", "priv", "sqlite3_nif.so"])

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(file),
         :ok <- arm64(file, "exqlite's NIF") do
      {:ok, sha256(file)}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "it must bundle exqlite #{version}'s priv/sqlite3_nif.so"}
    end
  end

  defp distribution(path) do
    with {:ok, [version]} <- File.ls(Path.join(path, "releases")) |> only_dirs(path),
         {:ok, text} <- File.read(Path.join([path, "releases", version, "env.sh"])),
         true <- text |> String.split("\n") |> Enum.any?(&(String.trim(&1) == @distribution)) do
      :ok
    else
      _ -> {:error, "releases/<vsn>/env.sh must turn distribution off (#{@distribution})"}
    end
  end

  # The names in `dir` starting with `prefix`.
  defp matching(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()}
      _ -> {:ok, []}
    end
  end

  defp only_dirs({:ok, names}, path),
    do: {:ok, Enum.filter(names, &File.dir?(Path.join([path, "releases", &1])))}

  defp only_dirs(error, _path), do: error

  # A thin ARM64 Mach-O, or a universal binary with an ARM64 slice.
  defp arm64(file, label) do
    case File.open(file, [:read, :binary], &IO.binread(&1, 4096)) do
      {:ok, <<0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, _::binary>>} ->
        :ok

      {:ok, <<0xCA, 0xFE, 0xBA, 0xBE, count::32-big, rest::binary>>} when count in 1..16 ->
        if fat_arm64?(rest, count), do: :ok, else: {:error, "#{label} has no ARM64 slice"}

      {:ok, _} ->
        {:error, "#{label} is not an ARM64 Mach-O"}

      _ ->
        {:error, "it must bundle #{label}"}
    end
  end

  defp fat_arm64?(_rest, 0), do: false
  defp fat_arm64?(<<0x0100000C::32-big, _::binary-16, _rest::binary>>, _count), do: true
  defp fat_arm64?(<<_::binary-20, rest::binary>>, count), do: fat_arm64?(rest, count - 1)
  defp fat_arm64?(_rest, _count), do: false

  defp sha256(file) do
    file
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
