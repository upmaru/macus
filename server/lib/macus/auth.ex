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

  @max_token_bytes 4_096
  # RFC 6750 b64token characters.
  @token ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @doc """
  The bearer token of a request's single `Authorization: Bearer <token>`
  header, at most 4 KiB of RFC 6750 token characters; `:error` otherwise.
  """
  @spec bearer_token(Plug.Conn.t()) :: {:ok, String.t()} | :error
  def bearer_token(%Plug.Conn{} = conn) do
    with [header] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         true <- byte_size(token) <= @max_token_bytes and Regex.match?(@token, token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  @doc """
  The state directory and owner UID that credentials and private sockets
  belong to: the running gateway's when serving, else `config :macus,
  :state_dir` with `config :macus, Macus.Auth, owner_uid:`.
  """
  @spec owner() :: {:ok, Macus.Configuration.t(), non_neg_integer()} | :error
  def owner do
    case Macus.Gateway.current() do
      %Macus.Gateway{state: state, uid: uid} ->
        {:ok, state, uid}

      nil ->
        with {:ok, state} <- Macus.Configuration.new(Application.get_env(:macus, :state_dir)),
             uid when is_integer(uid) and uid >= 0 <-
               Keyword.get(Application.get_env(:macus, __MODULE__, []), :owner_uid) do
          {:ok, state, uid}
        else
          _ -> :error
        end
    end
  end
end
