defmodule Macus.Dex.RuntimeExecutor do
  @moduledoc """
  The `Tama.Dex.Executor` for the `macus` source: runs the
  `Macus.Dex.RuntimeDocument` operations over the private Swift runtime API
  (`Macus.Runtime`), sending the same requests as the Swift `macus` CLI.

  Before anything is sent, the caller must be the verified
  `TamaMCP.Context` carrying the configured owner key, the operation's scope
  must be in both `call.scopes` and the caller's own scopes, and a
  destructive operation's `confirm` token must match. The runtime socket is
  always `<state-dir>/runtime.sock` from trusted configuration and must be
  owner-private (`Macus.Runtime.Client`).

  Reads return the native record (status without the private
  `incus_socket` path). Lifecycle operations return `%{"status", "state",
  "runtime", "wait_error"}`: `completed` with the runtime status when the
  runtime replied, or `uncertain` when the request may have been accepted
  but no reply arrived within the bounded wait. Nothing is resent. A native
  error, including the 409 for an unmet stopped-state precondition, is
  returned as `%{"error" => %{"code", "message", "http_status"}}`.

  ## Configuration

  The state directory is `config :macus, :state_dir`. Executor settings are
  `config :macus, Macus.Dex.RuntimeExecutor, ...`: `:owner_uid` (owner of
  `runtime.sock`), `:owner_key` (the key verified callers carry),
  `:read_timeout_ms` (default 15 000) and `:mutation_timeout_ms` (default
  25 000, below the MCP request deadline). Missing configuration denies
  every call.
  """

  @behaviour Tama.Dex.Executor

  alias Macus.{Configuration, Runtime}
  alias Macus.Dex.RuntimeDocument
  alias Macus.Runtime.{Client, Error, Response}

  @reads %{
    "macus_runtime_status" => :status,
    "macus_runtime_progress" => :progress,
    "macus_runtime_health" => :health,
    "macus_runtime_capabilities" => :capabilities,
    "macus_runtime_config_get" => :config
  }
  @mutations ~w(macus_runtime_create macus_runtime_start macus_runtime_stop
                macus_runtime_force_stop macus_runtime_restart
                macus_runtime_config_update macus_runtime_delete)
  @scopes Map.merge(
            Map.new(Map.keys(@reads), &{&1, "runtime.read"}),
            %{
              "macus_runtime_create" => "runtime.write",
              "macus_runtime_start" => "runtime.write",
              "macus_runtime_stop" => "runtime.write",
              "macus_runtime_restart" => "runtime.write",
              "macus_runtime_config_update" => "runtime.write",
              "macus_runtime_force_stop" => "runtime.delete",
              "macus_runtime_delete" => "runtime.delete"
            }
          )
  @message_bytes 1024

  @impl Tama.Dex.Executor
  def execute(%Tama.Dex.Call{} = call, input) when is_map(input) do
    with {:ok, scope} <- scope(call.operation_id),
         {:ok, config} <- config(),
         :ok <- verify(call.context, config),
         :ok <- authorize(scope, call.scopes, call.context.scopes),
         :ok <- confirm(call.operation_id, input),
         {:ok, client} <- client(config) do
      dispatch(call.operation_id, input, client, config)
    end
  end

  def execute(_call, _input), do: denied("invalid_input", "The input must be an object.")

  # Before dispatch

  defp scope(operation_id) do
    case Map.fetch(@scopes, operation_id) do
      {:ok, scope} -> {:ok, scope}
      :error -> denied("unknown_operation", "No Macus runtime operation has this ID.")
    end
  end

  defp verify(
         %TamaMCP.Context{principal: principal, owner_key: key, scopes: scopes},
         %{owner_key: key}
       )
       when not is_nil(principal) and not is_nil(key) and is_list(scopes),
       do: :ok

  defp verify(_context, _config),
    do: denied("unauthorized", "The caller is not the verified Macus owner.")

  defp authorize(scope, call_scopes, caller_scopes) do
    if is_list(call_scopes) and scope in call_scopes and scope in caller_scopes,
      do: :ok,
      else: denied("forbidden", "The caller lacks the #{scope} scope.")
  end

  defp confirm(operation_id, input) do
    case RuntimeDocument.confirmation(operation_id) do
      nil ->
        :ok

      token ->
        if input["confirm"] === token,
          do: :ok,
          else: denied("confirmation_required", "Set confirm to #{inspect(token)}.")
    end
  end

  defp client(config) do
    case Client.new(config.state, config.owner_uid) do
      {:ok, client} -> {:ok, client}
      {:error, %Error{}} -> denied("unavailable", "The runtime socket is not configured.")
    end
  end

  # Dispatch: the requests the Swift CLI sends.

  defp dispatch(operation_id, _input, client, config) when is_map_key(@reads, operation_id) do
    endpoint = Map.fetch!(@reads, operation_id)
    response = apply(Runtime, endpoint, [client, [timeout_ms: config.read_timeout_ms]])
    read_result(response, operation_id)
  end

  defp dispatch(operation_id, input, client, config) when operation_id in @mutations do
    opts = [timeout_ms: config.mutation_timeout_ms]

    response =
      case operation_id do
        "macus_runtime_create" -> Runtime.create(client, input, opts)
        "macus_runtime_start" -> Runtime.start(client, budget(input), opts)
        "macus_runtime_stop" -> Runtime.stop(client, %{"force" => false}, opts)
        "macus_runtime_force_stop" -> Runtime.stop(client, %{"force" => true}, opts)
        "macus_runtime_restart" -> Runtime.restart(client, opts)
        "macus_runtime_config_update" -> Runtime.update(client, input, opts)
        "macus_runtime_delete" -> Runtime.delete(client, %{"confirm" => true}, opts)
      end

    mutation_result(response)
  end

  defp budget(%{"remaining_seconds" => seconds}), do: %{"remaining_seconds" => seconds}
  defp budget(_input), do: nil

  # Results

  defp read_result({:ok, %Response{status: status, body: body}}, operation_id)
       when status in 200..299 do
    case decode(body) do
      {:ok, record} -> {:ok, project(record, operation_id)}
      :error -> invalid_response()
    end
  end

  defp read_result(response, _operation_id), do: failure(response)

  defp mutation_result({:ok, %Response{status: status, body: body}}) when status in 200..299 do
    case decode(body) do
      {:ok, runtime} ->
        runtime = Map.delete(runtime, "incus_socket")

        {:ok,
         %{
           "status" => "completed",
           "state" => string_or_nil(runtime["state"]),
           "runtime" => runtime,
           "wait_error" => nil
         }}

      :error ->
        invalid_response()
    end
  end

  # The request may have reached Swift: report it, never resend it.
  defp mutation_result({:error, %Error{outcome: :unknown, code: code}}) do
    {:ok,
     %{
       "status" => "uncertain",
       "state" => nil,
       "runtime" => nil,
       "wait_error" => Atom.to_string(code)
     }}
  end

  defp mutation_result(response), do: failure(response)

  defp project(record, "macus_runtime_status"), do: Map.delete(record, "incus_socket")
  defp project(record, _operation_id), do: record

  defp failure({:ok, %Response{status: status, body: body}}) do
    {code, message} =
      case decode(body) do
        {:ok, %{"error" => %{"code" => code, "message" => message}}}
        when is_binary(code) and is_binary(message) ->
          {code, message}

        _ ->
          {"invalid_response", "The runtime returned HTTP #{status}."}
      end

    {:error,
     %{"error" => %{"code" => code, "message" => bounded(message), "http_status" => status}}}
  end

  defp failure({:error, %Error{code: code, outcome: outcome}}) do
    {:error,
     %{
       "error" => %{
         "code" => Atom.to_string(code),
         "message" => "The runtime request failed (#{code}).",
         "outcome" => Atom.to_string(outcome)
       }
     }}
  end

  defp invalid_response do
    {:error,
     %{
       "error" => %{
         "code" => "invalid_response",
         "message" => "The runtime reply was not a JSON object.",
         "outcome" => "unknown"
       }
     }}
  end

  defp denied(code, message),
    do:
      {:error,
       %{"error" => %{"code" => code, "message" => message, "outcome" => "not_dispatched"}}}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :error
    end
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp bounded(message) when byte_size(message) <= @message_bytes, do: message
  defp bounded(message), do: String.slice(message, 0, 1000) <> "…"

  # Configuration, read per call; anything invalid denies.

  defp config do
    env = Application.get_env(:macus, __MODULE__, [])

    with {:ok, state} <- Configuration.new(Application.get_env(:macus, :state_dir)),
         uid when is_integer(uid) and uid >= 0 <- Keyword.get(env, :owner_uid),
         key when not is_nil(key) <- Keyword.get(env, :owner_key),
         read when read in 1..3_600_000 <- Keyword.get(env, :read_timeout_ms, 15_000),
         mutation when mutation in 1..3_600_000 <- Keyword.get(env, :mutation_timeout_ms, 25_000) do
      {:ok,
       %{
         state: state,
         owner_uid: uid,
         owner_key: key,
         read_timeout_ms: read,
         mutation_timeout_ms: mutation
       }}
    else
      _ -> denied("unavailable", "The Macus runtime executor is not configured.")
    end
  end
end
