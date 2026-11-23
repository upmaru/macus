defmodule Macus.MCP.Cache do
  @moduledoc """
  `TamaMCP.Cache` for compiled validators. TamaMCP's keys are versioned and
  bounded by the compiled catalogue (two tools plus the fixed protocol
  validators), so values live in `:persistent_term` for the node's life.
  """

  @behaviour TamaMCP.Cache

  @impl true
  def fetch(key, loader, _options) when is_binary(key) and is_function(loader, 0) do
    term_key = {__MODULE__, key}

    case :persistent_term.get(term_key, :missing) do
      :missing ->
        value = loader.()
        :persistent_term.put(term_key, value)
        {:ok, value}

      value ->
        {:ok, value}
    end
  rescue
    exception -> {:error, {:loader_failed, exception.__struct__}}
  end

  def fetch(_key, _loader, _options), do: {:error, :invalid_key}
end
