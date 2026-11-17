defmodule Macus.TestSupport.DexFixtures do
  @moduledoc false

  # Minimal tama-operations/1 documents and cassettes for index tests.

  def document(source, operation_ids, version \\ "1.0.0") do
    paths =
      Map.new(operation_ids, fn id ->
        {"/operations/#{id}",
         %{
           "post" => %{
             "operationId" => id,
             "summary" => "Fixture #{id}",
             "description" => "Fixture operation #{id} for Macus index tests.",
             "x-tama-scopes" => ["fixture.read"],
             "x-tama-destructive" => false,
             "requestBody" => %{
               "required" => true,
               "content" => %{
                 "application/json" => %{
                   "schema" => %{"type" => "object", "additionalProperties" => false}
                 }
               }
             },
             "responses" => %{
               "200" => %{
                 "description" => "Result",
                 "content" => %{"application/json" => %{"schema" => %{"type" => "object"}}}
               }
             }
           }
         }}
      end)

    %{
      "openapi" => "3.1.1",
      "info" => %{"title" => "#{source} fixture operations", "version" => version},
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => source,
      "paths" => paths
    }
  end

  def cassette!(dir, name, version, documents) do
    path = Path.join(dir, "#{name}-#{version}.tama-cassette")
    {:ok, built} = Tama.Dex.Cassette.build(documents, path, name: name, version: version)
    %{path: path, sha256: built.sha256}
  end

  def private_root! do
    root = Path.join("/private/tmp", "mc-dex-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  def handle_event(_event, _measurements, metadata, pid) do
    send(pid, {:dex_event, metadata.cassette, metadata.status})
  end
end
