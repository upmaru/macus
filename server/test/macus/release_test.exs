defmodule Macus.ReleaseTest do
  # Task 8.3: the release records the identity `macus start` pairs with.
  use ExUnit.Case, async: false

  @revision String.duplicate("ab", 20)

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

    %{dir: dir}
  end

  test "the manifest names this build and its bundled library" do
    Application.put_env(:macus, Macus.Build, revision: @revision)
    manifest = Macus.Build.manifest()
    identity = Macus.Build.identity()

    assert manifest == %{
             "schema_version" => 1,
             "version" => identity.version,
             "revision" => @revision,
             "opsmaru_incus" => %{
               "version" => identity.opsmaru_incus.version,
               "checksum" => identity.opsmaru_incus.checksum
             }
           }

    assert manifest["opsmaru_incus"]["version"] ==
             to_string(Application.spec(:opsmaru_incus, :vsn))
  end

  test "the release step writes it at the release root, readable but not writable by others",
       ctx do
    Application.put_env(:macus, Macus.Build, revision: @revision)
    release = %{path: ctx.dir}
    assert Macus.Release.write_manifest(release) == release

    file = Path.join(ctx.dir, "macus-build.json")
    assert Jason.decode!(File.read!(file)) == Macus.Build.manifest()
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o644
  end

  test "a build without a valid source revision assembles no manifest", ctx do
    for revision <- [nil, "HEAD", String.upcase(@revision)] do
      Application.put_env(:macus, Macus.Build, revision: revision)

      assert_raise Mix.Error, ~r/MACUS_SOURCE_REVISION/, fn ->
        Macus.Release.write_manifest(%{path: ctx.dir})
      end

      refute File.exists?(Path.join(ctx.dir, "macus-build.json"))
    end
  end

  test "mix.exs runs the step after assembly" do
    config = Mix.Project.config()[:releases][:macus]
    assert config[:steps] == [:assemble, &Macus.Release.write_manifest/1]
  end
end
