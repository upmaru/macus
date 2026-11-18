defmodule Macus.Release do
  @moduledoc """
  Release build steps.

  `write_manifest/1` runs after `:assemble` and writes `macus-build.json`
  (`Macus.Build.manifest/0`) at the release root, beside `bin/`, `lib/`,
  `releases/` and the bundled `erts-*`. `macus start` reads it before it
  starts this release and refuses a release whose revision or version
  differs from the Swift executable's, or whose recorded `opsmaru_incus`
  is not the one under `lib/`. A build that recorded no valid source
  revision fails here, so no unpaired release is assembled.
  """

  @manifest "macus-build.json"

  @doc "The manifest's file name at the release root."
  def manifest_name, do: @manifest

  @doc "Release step: writes the build manifest (0644) at the release root."
  @spec write_manifest(Mix.Release.t()) :: Mix.Release.t()
  def write_manifest(%{path: path} = release) do
    manifest = Macus.Build.manifest()

    unless Macus.Build.revision?(manifest["revision"]) do
      Mix.raise(
        "The Macus release needs MACUS_SOURCE_REVISION (40 or 64 lowercase hex) at build time"
      )
    end

    file = Path.join(path, @manifest)
    File.write!(file, Jason.encode_to_iodata!(manifest, pretty: true) |> then(&[&1, ?\n]))
    File.chmod!(file, 0o644)
    release
  end
end
