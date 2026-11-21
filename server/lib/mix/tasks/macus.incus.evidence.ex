defmodule Mix.Tasks.Macus.Incus.Evidence do
  @shortdoc "Checks the linked opsmaru_incus evidence and regenerates docs/incus-evidence.md"
  @moduledoc """
  Checks that the evidence the locked `:opsmaru_incus` package ships is
  exactly the locked package's, is well formed and self-consistent, and is
  linked to Macus's consumer bindings; then writes or checks
  `docs/incus-evidence.md`.

      mix macus.incus.evidence             # write the file
      mix macus.incus.evidence --check     # fail on any error or a stale file

  The check reads only the locked package and Macus's own manifest; it does
  not run the library's tests, and it never claims hardware acceptance.
  See `Macus.Incus.Evidence` for what it verifies.
  """

  use Mix.Task

  @path Path.expand("../../../../docs/incus-evidence.md", __DIR__)

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [check: :boolean])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix macus.incus.evidence [--check]")

    Mix.Task.run("compile")

    case Macus.Incus.Evidence.check() do
      {:ok, _summary} ->
        :ok

      {:error, %{errors: errors}} ->
        Mix.shell().error("The linked opsmaru_incus evidence check failed:")

        for error <- errors, do: Mix.shell().error("  #{error}")

        Mix.raise("fix the locked dependency or its evidence before checking")
    end

    check? = opts[:check] == true

    cond do
      check? and File.read(@path) != {:ok, Macus.Incus.Evidence.markdown()} ->
        Mix.raise("#{@path} is out of date; run `mix macus.incus.evidence`")

      check? ->
        Mix.shell().info("The linked opsmaru_incus evidence checks out.")

      true ->
        File.write!(@path, Macus.Incus.Evidence.markdown())
        Mix.shell().info("Wrote #{@path}")
    end
  end
end
