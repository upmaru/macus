defmodule Macus.Auth.Streams do
  @moduledoc """
  Closes active gateway streams whose credential is revoked or expires.

  Every stream authenticated by a Macus credential registers its process
  here, keyed by the credential, before any backend work starts.
  `Macus.Auth.Streams.Watcher` rechecks every registered credential against
  the current gateway state on a fixed interval and terminates the processes
  of any credential that is no longer valid, so a revoked or expired
  credential's streams close within the documented bound (`bound_ms/0`,
  default 5 seconds). New requests are refused at once, since each request
  verifies against the store.

  A registration ends when its process exits or calls `unregister/0`. If the
  registry is not running a stream cannot be tracked, so `register/2` fails
  and the caller must refuse the request.

  Credentials:

    * `{:bearer, id, verifier, scopes}` - valid while the store still holds a
      current (unrevoked, unexpired) record with that ID, verifier and scopes.

  Configuration: `config :macus, Macus.Auth.Streams, bound_ms: 5_000,
  grace_ms: 500`. The watcher checks every `bound_ms - grace_ms` and kills a
  terminated process that is still alive `grace_ms` later.
  """

  alias Macus.Auth.{Bearer, Token}

  @registry Macus.Auth.Streams.Registry
  @default_bound_ms 5_000
  @default_grace_ms 500

  @type credential :: {:bearer, String.t(), String.t(), [String.t()]}

  @doc "The registry and watcher, for the application supervisor."
  def child_specs(opts \\ []) do
    [
      {Registry, keys: :duplicate, name: @registry},
      {Macus.Auth.Streams.Watcher, opts}
    ]
  end

  @doc "The registry name."
  def registry, do: @registry

  @doc "The documented closure bound in milliseconds."
  @spec bound_ms() :: pos_integer()
  def bound_ms, do: elem(timing(), 0)

  @doc false
  def timing do
    env = Application.get_env(:macus, __MODULE__, [])
    bound = Keyword.get(env, :bound_ms, @default_bound_ms)
    grace = Keyword.get(env, :grace_ms, @default_grace_ms)

    if is_integer(bound) and is_integer(grace) and grace > 0 and bound > grace,
      do: {bound, grace},
      else: {@default_bound_ms, @default_grace_ms}
  end

  @doc """
  Registers the calling process as a stream of `credential`, expiring at
  `expires_at` (`nil` for none). Returns `:error` when it cannot be tracked.
  """
  @spec register(credential(), DateTime.t() | nil) :: :ok | :error
  def register({:bearer, id, verifier, scopes} = credential, expires_at)
      when is_binary(id) and is_binary(verifier) and is_list(scopes) and
             (is_nil(expires_at) or is_struct(expires_at, DateTime)) do
    case Registry.register(@registry, credential_key(credential), %{
           credential: credential,
           expires_at: expires_at
         }) do
      {:ok, _owner} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def register(_credential, _expires_at), do: :error

  @doc "Ends every registration of the calling process."
  @spec unregister() :: :ok
  def unregister do
    for key <- Registry.keys(@registry, self()), do: Registry.unregister(@registry, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Registered `{pid, value}` entries."
  @spec entries() :: [{pid(), map()}]
  def entries do
    Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the entries whose credential is no longer valid at `now`. The
  gateway state is read once per call; if it cannot be read, every bearer
  stream is invalid.
  """
  @spec invalid([{pid(), map()}], DateTime.t()) :: [{pid(), map()}]
  def invalid(entries, now) do
    records =
      if Enum.any?(entries, &match?({_, %{credential: {:bearer, _, _, _}}}, &1)),
        do: bearer_records(),
        else: :error

    Enum.reject(entries, fn {_pid, entry} -> valid?(entry, records, now) end)
  end

  defp valid?(%{expires_at: %DateTime{} = expires_at} = entry, records, now) do
    DateTime.compare(expires_at, now) == :gt and
      valid?(%{entry | expires_at: nil}, records, now)
  end

  defp valid?(%{credential: {:bearer, id, verifier, scopes}}, {:ok, records}, now) do
    case Map.fetch(records, id) do
      {:ok, record} ->
        record["verifier"] == verifier and record["scopes"] == scopes and
          Token.scopes?(scopes) and Bearer.current?(record, now)

      :error ->
        false
    end
  end

  defp valid?(_entry, _records, _now), do: false

  defp bearer_records do
    with {:ok, state, uid} <- Bearer.config() do
      Bearer.load(Bearer.path(state), uid)
    end
  end

  defp credential_key({:bearer, id, _verifier, _scopes}), do: {:bearer, id}
end
