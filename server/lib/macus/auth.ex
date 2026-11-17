defmodule Macus.Auth do
  @moduledoc """
  Gateway-owned certificate trust and scoped bearer authorization boundary.
  Guest certificate trust never authorizes access to a privileged host socket.
  Keys, verifiers and revocation state belong in private gateway state.

  Bearer credentials are `Macus.Auth.Token`s verified by `Macus.Auth.Bearer`
  against `<state-dir>/server/bearer-tokens.json`. Every credential belongs
  to the single host owner, whose key is `owner_key/1`.
  """

  @doc """
  The owner key verified callers carry: the host owner's UID. The Incus
  operations host and the runtime executor compare it with their configured
  owner key.
  """
  @spec owner_key(non_neg_integer()) :: String.t()
  def owner_key(uid) when is_integer(uid) and uid >= 0, do: "macus-owner:#{uid}"
end
