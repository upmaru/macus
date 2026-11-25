defmodule Macus.TestSupport.AccessLogAudit do
  @moduledoc false
  # What the gateway access log may contain, checked against the file a
  # test's exchanges produced.

  @keys ~w(v id time protocol method path project target all_projects operation peer
           certificate admitted_as status outcome reason duration_ms request_bytes
           response_bytes dropped_before)

  # Never part of a record, whatever the exchange: credential schemes, query
  # strings, secret parameters and PEM bodies.
  @never ["Bearer ", "Basic ", "authorization", "secret", "?", "-----BEGIN"]

  @doc "The documented record keys, `dropped_before` included."
  def keys, do: @keys

  @doc """
  Every way `text`, the log file's content, breaks the redaction rule:
  a line that is not a JSON object, a key outside the documented set, a
  generic secret marker, or one of the test's own `secrets`.
  """
  def violations(text, secrets \\ []) do
    for line <- String.split(text, "\n", trim: true),
        violation <- line_violations(line, secrets),
        do: violation
  end

  defp line_violations(line, secrets) do
    case Jason.decode(line) do
      {:ok, %{} = record} ->
        unknown = for key <- Map.keys(record), key not in @keys, do: "unknown key #{key}: #{line}"

        found =
          for text <- @never ++ secrets, String.contains?(line, text), do: "#{text}: #{line}"

        unknown ++ found

      _ ->
        ["not a JSON object: #{line}"]
    end
  end
end
