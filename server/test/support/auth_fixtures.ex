defmodule Macus.TestSupport.AuthFixtures do
  @moduledoc false

  alias Macus.Auth.Token

  @doc "A private state directory with a private gateway directory, and its owner UID."
  def state!(root) do
    state = Path.join(root, "state-#{System.unique_integer([:positive])}")
    gateway = Path.join(state, "server")
    File.mkdir_p!(gateway)
    File.chmod!(state, 0o700)
    File.chmod!(gateway, 0o700)
    {state, File.stat!(state).uid}
  end

  @doc "Writes `records` as the owner-private bearer token store."
  def store!(state, records, mode \\ 0o600) do
    path = Path.join([state, "server", "bearer-tokens.json"])
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "tokens" => records}))
    File.chmod!(path, mode)
    path
  end

  @doc "A token and its record; fails the test on refusal."
  def token!(scopes, opts \\ []) do
    {:ok, token, record} = Token.new(Keyword.get(opts, :principal, "owner"), scopes, opts)
    {token, record}
  end

  @doc "Points the bearer verifier at `state` and `uid` until the test exits."
  def configure!(state, uid) do
    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, Macus.Auth)}

    Application.put_env(:macus, :state_dir, state)
    Application.put_env(:macus, Macus.Auth, owner_uid: uid)

    ExUnit.Callbacks.on_exit(fn ->
      {dir, auth} = previous
      restore(:state_dir, dir)
      restore(Macus.Auth, auth)
    end)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)
end
