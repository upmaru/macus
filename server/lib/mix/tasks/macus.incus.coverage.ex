defmodule Mix.Tasks.Macus.Incus.Coverage do
  @shortdoc "Regenerates docs/incus-coverage.md from the locked opsmaru_incus package"
  @moduledoc """
  Writes `docs/incus-coverage.md` from `Macus.Incus.Coverage.markdown/0`,
  or compares the locked dependency's inventory with an earlier one.

      mix macus.incus.coverage                    # write the file
      mix macus.incus.coverage --check            # fail if the file is out of date
      mix macus.incus.coverage --diff OLD.json    # added, removed and changed declarations

  `--diff` takes the `inventory.json` record shipped by the previously
  locked `opsmaru_incus` and prints `Opsmaru.Incus.Inventory.diff/2` against the
  current one, so a dependency update shows every changed declaration.
  """

  use Mix.Task

  @path Path.expand("../../../../docs/incus-coverage.md", __DIR__)

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [check: :boolean, diff: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix macus.incus.coverage [--check | --diff OLD_INVENTORY]")

    Mix.Task.run("compile")

    cond do
      opts[:diff] ->
        previous = opts[:diff] |> File.read!() |> Jason.decode!()
        diff = Opsmaru.Incus.Inventory.diff(previous, Macus.Incus.Coverage.inventory())

        for {change, ids} <- [added: diff.added, removed: diff.removed, changed: diff.changed] do
          Mix.shell().info("#{change}: #{length(ids)}")
          for id <- ids, do: Mix.shell().info("  #{id}")
        end

      opts[:check] ->
        unless File.read(@path) == {:ok, Macus.Incus.Coverage.markdown()},
          do: Mix.raise("#{@path} is out of date; run `mix macus.incus.coverage`")

      true ->
        File.write!(@path, Macus.Incus.Coverage.markdown())
        Mix.shell().info("Wrote #{@path}")
    end
  end
end
