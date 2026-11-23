defmodule Mix.Tasks.Macus.Mcp.Manifest do
  @shortdoc "Regenerates docs/mcp-operations.md from the indexed operation documents"
  @moduledoc """
  Writes `docs/mcp-operations.md` from `Macus.MCP.Manifest.markdown/0`.

      mix macus.mcp.manifest          # write the file
      mix macus.mcp.manifest --check  # fail if the file is out of date
  """

  use Mix.Task

  @path Path.expand("../../../../docs/mcp-operations.md", __DIR__)

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])
    Mix.Task.run("compile")
    content = Macus.MCP.Manifest.markdown()

    if opts[:check] do
      unless File.read(@path) == {:ok, content},
        do: Mix.raise("#{@path} is out of date; run `mix macus.mcp.manifest`")
    else
      File.write!(@path, content)
      Mix.shell().info("Wrote #{@path}")
    end
  end
end
