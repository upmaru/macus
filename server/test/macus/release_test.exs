defmodule Macus.ReleaseTest do
  # Tasks 8.3 and 9.1: the release records the identity `macus start` pairs
  # with, and only a complete, self-contained macOS ARM64 release is recorded.
  use ExUnit.Case, async: false

  @revision String.duplicate("ab", 20)
  @arch "aarch64-apple-darwin24.6.0"
  # A thin ARM64 Mach-O header (MH_MAGIC_64, CPU_TYPE_ARM64).
  @arm64 <<0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01>> <> :binary.copy(<<0>>, 24)
  @x86_64 <<0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01>> <> :binary.copy(<<0>>, 24)
  @cassette "fixture cassette bytes"

  setup do
    previous = Application.get_env(:macus, Macus.Build)
    dir = Path.join(System.tmp_dir!(), "mc-rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:macus, Macus.Build, previous),
        else: Application.delete_env(:macus, Macus.Build)

      File.rm_rf!(dir)
    end)

    pin = sha256(@cassette)
    Application.put_env(:macus, Macus.Build, revision: @revision, cassette_sha256: pin)
    release(dir)
    %{dir: dir, pin: pin}
  end

  # A release tree with what Macus.Release checks.
  defp release(dir) do
    lib = Path.join(dir, "lib")
    write(Path.join([dir, "erts-15.2.7.12", "bin", "beam.smp"]), @arm64)

    for name <- [:opsmaru_incus, :tama_dex] do
      write(Path.join([lib, "#{name}-#{Macus.Build.locked(name).version}", "ebin", "x"]), "")
    end

    write(
      Path.join([lib, "macus-0.1.0", "priv", "cassettes", Macus.Build.cassette_file()]),
      @cassette
    )

    write(nif_path(dir), @arm64)

    write(
      Path.join([dir, "releases", "0.1.0", "env.sh"]),
      "#!/bin/sh\n" <> Macus.Release.distribution_line() <> "\n"
    )

    write(Path.join([dir, "releases", "start_erl.data"]), "15.2.7.12 0.1.0\n")
  end

  defp nif_path(dir),
    do:
      Path.join([
        dir,
        "lib",
        "exqlite-#{Macus.Build.locked(:exqlite).version}",
        "priv",
        "sqlite3_nif.so"
      ])

  defp cassette_path(dir),
    do: Path.join([dir, "lib", "macus-0.1.0", "priv", "cassettes", Macus.Build.cassette_file()])

  defp write(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, data)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp verify(dir), do: Macus.Release.verify(dir, architecture: @arch)

  test "a complete release is verified and the manifest records it", ctx do
    assert {:ok, bundle} = verify(ctx.dir)

    assert bundle == %{
             cassette_sha256: ctx.pin,
             nif_sha256: sha256(@arm64),
             erts: "15.2.7.12",
             target: "aarch64-apple-darwin"
           }

    identity = Macus.Build.identity()
    tama_dex = Macus.Build.locked(:tama_dex)
    exqlite = Macus.Build.locked(:exqlite)

    assert Macus.Build.manifest(bundle) == %{
             "schema_version" => 1,
             "version" => identity.version,
             "revision" => @revision,
             "opsmaru_incus" => %{
               "version" => identity.opsmaru_incus.version,
               "checksum" => identity.opsmaru_incus.checksum,
               "cassette" => %{"file" => Macus.Build.cassette_file(), "sha256" => ctx.pin}
             },
             "tama_dex" => %{"version" => tama_dex.version, "checksum" => tama_dex.checksum},
             "exqlite" => %{
               "version" => exqlite.version,
               "checksum" => exqlite.checksum,
               "nif_sha256" => sha256(@arm64)
             },
             "erts" => %{"version" => "15.2.7.12", "target" => "aarch64-apple-darwin"},
             "distribution" => "none"
           }

    # Recorded versions are the loaded, locked dependencies.
    for name <- [:opsmaru_incus, :tama_dex, :exqlite] do
      assert Macus.Build.locked(name).version == to_string(Application.spec(name, :vsn))
    end
  end

  test "the step writes the manifest read-only at the release root, replacing an earlier one",
       ctx do
    File.write!(Path.join(ctx.dir, "macus-build.json"), "stale")
    File.chmod!(Path.join(ctx.dir, "macus-build.json"), 0o444)

    release = %{path: ctx.dir}

    assert Macus.Release.write_manifest(release, architecture: @arch) == release

    file = Path.join(ctx.dir, "macus-build.json")
    {:ok, bundle} = verify(ctx.dir)
    assert Jason.decode!(File.read!(file)) == Macus.Build.manifest(bundle)
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o444
  end

  test "a build without a valid source revision assembles no manifest", ctx do
    for revision <- [nil, "HEAD", String.upcase(@revision)] do
      Application.put_env(:macus, Macus.Build, revision: revision, cassette_sha256: ctx.pin)
      assert {:error, message} = verify(ctx.dir)
      assert message =~ "MACUS_SOURCE_REVISION"

      assert_raise Mix.Error, ~r/MACUS_SOURCE_REVISION/, fn ->
        Macus.Release.write_manifest(%{path: ctx.dir}, architecture: @arch)
      end

      refute File.exists?(Path.join(ctx.dir, "macus-build.json"))
    end
  end

  test "only a macOS ARM64 build host and ERTS are accepted", ctx do
    assert {:error, message} = Macus.Release.verify(ctx.dir, architecture: "x86_64-apple-darwin")
    assert message =~ "aarch64-apple-darwin"

    assert {:error, _} = Macus.Release.verify(ctx.dir, architecture: "aarch64-unknown-linux-gnu")

    beam = Path.join([ctx.dir, "erts-15.2.7.12", "bin", "beam.smp"])
    File.write!(beam, @x86_64)
    assert {:error, message} = verify(ctx.dir)
    assert message =~ "ERTS is not an ARM64"

    # A universal binary with an ARM64 slice is accepted.
    File.write!(
      beam,
      <<0xCA, 0xFE, 0xBA, 0xBE, 2::32-big, 0x01000007::32-big, 0::128, 0x0100000C::32-big,
        0::128>>
    )

    assert {:ok, _} = verify(ctx.dir)

    write(Path.join([ctx.dir, "erts-15.2.7.11", "bin", "beam.smp"]), @arm64)
    assert {:error, "it must bundle exactly one ERTS"} = verify(ctx.dir)
    File.rm_rf!(Path.join(ctx.dir, "erts-15.2.7.11"))
    File.rm_rf!(Path.join(ctx.dir, "erts-15.2.7.12"))
    assert {:error, "it must bundle exactly one ERTS"} = verify(ctx.dir)
  end

  test "the locked libraries must be bundled, alone", ctx do
    for name <- [:opsmaru_incus, :tama_dex] do
      locked = Path.join([ctx.dir, "lib", "#{name}-#{Macus.Build.locked(name).version}"])
      other = Path.join([ctx.dir, "lib", "#{name}-0.0.1"])

      File.rename!(locked, other)
      assert {:error, message} = verify(ctx.dir)
      assert message =~ "#{name} #{Macus.Build.locked(name).version}"

      File.mkdir_p!(locked)
      assert {:error, _} = verify(ctx.dir)
      File.rm_rf!(other)
      assert {:ok, _} = verify(ctx.dir)
    end
  end

  test "the cassette must be bundled alone and match the recorded pin", ctx do
    Application.put_env(:macus, Macus.Build, revision: @revision)
    assert {:error, message} = verify(ctx.dir)
    assert message =~ "MACUS_CASSETTE_SHA256"

    Application.put_env(:macus, Macus.Build, revision: @revision, cassette_sha256: "ABC")
    assert {:error, _} = verify(ctx.dir)

    Application.put_env(:macus, Macus.Build,
      revision: @revision,
      cassette_sha256: String.duplicate("0", 64)
    )

    assert {:error, message} = verify(ctx.dir)
    assert message =~ "matching MACUS_CASSETTE_SHA256"

    Application.put_env(:macus, Macus.Build, revision: @revision, cassette_sha256: ctx.pin)
    extra = Path.join(Path.dirname(cassette_path(ctx.dir)), "opsmaru_incus-0.0.1.tama-cassette")
    File.write!(extra, @cassette)
    assert {:error, _} = verify(ctx.dir)
    File.rm!(extra)

    File.rm!(cassette_path(ctx.dir))
    File.ln_s!(extra, cassette_path(ctx.dir))
    File.write!(extra, @cassette)
    assert {:error, _} = verify(ctx.dir)
  end

  test "exqlite's NIF must be bundled for ARM64", ctx do
    File.write!(nif_path(ctx.dir), @x86_64)
    assert {:error, message} = verify(ctx.dir)
    assert message =~ "NIF is not an ARM64"

    File.rm!(nif_path(ctx.dir))
    assert {:error, message} = verify(ctx.dir)
    assert message =~ "sqlite3_nif.so"
  end

  test "env.sh must turn distribution off", ctx do
    env = Path.join([ctx.dir, "releases", "0.1.0", "env.sh"])

    for text <- [
          "#!/bin/sh\n",
          "# #{Macus.Release.distribution_line()}\n",
          "export RELEASE_DISTRIBUTION=sname\n"
        ] do
      File.write!(env, text)
      assert {:error, message} = verify(ctx.dir)
      assert message =~ "distribution off"
    end
  end

  test "the release template keeps distribution off" do
    template = File.read!(Path.expand("../../rel/env.sh.eex", __DIR__))
    assert template |> String.split("\n") |> Enum.member?(Macus.Release.distribution_line())
  end

  test "mix.exs bundles ERTS and runs the step after assembly" do
    config = Mix.Project.config()[:releases][:macus]
    assert config[:include_erts] == true
    assert config[:steps] == [:assemble, &Macus.Release.write_manifest/1]
  end
end
