defmodule Macus.MCP.Authorization do
  @moduledoc """
  The `TamaMCP.Authorization` adapter for `/mcp`: every request must carry a
  Macus bearer credential, `Authorization: Bearer <token>`.

  The token is checked by the configured verifier, `config :macus,
  Macus.MCP.Authorization, verifier: {module, function, args}`, called as
  `apply(module, function, [token | args])`. It returns `{:ok, %{principal:
  term, owner_key: term, scopes: [String.t()], expires_at: DateTime.t() |
  nil}}` (optionally `claims: map`) or `{:error, reason}`. Macus's own token
  store provides the verifier (task 3.3); until one is configured every
  request is refused with 401.

  Identity comes only from the verifier. A missing, malformed or oversized
  credential, a verifier that fails or returns anything else, an expired
  credential, or a result without a principal, owner key or valid scopes is
  refused before any tool runs. The token and verifier reason are never
  logged or echoed.
  """

  use TamaMCP.Authorization

  alias TamaMCP.Authorization.Decision

  @max_token_bytes 4_096
  # RFC 6750 b64token characters.
  @token ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  @impl true
  def authenticate(conn, _options) do
    with {:ok, token} <- bearer(conn),
         {:ok, verified} <- verify(token),
         {:ok, decision} <- decision(verified) do
      {:ok, decision}
    else
      _ -> {:error, TamaMCP.Error.invalid_request("A valid Macus bearer credential is required")}
    end
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [header] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] ->
            if String.downcase(scheme) == "bearer" and byte_size(token) <= @max_token_bytes and
                 Regex.match?(@token, token),
               do: {:ok, token},
               else: :error

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp verify(token) do
    case Keyword.get(Application.get_env(:macus, __MODULE__, []), :verifier) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        case apply(module, function, [token | args]) do
          {:ok, verified} when is_map(verified) -> {:ok, verified}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp decision(%{principal: principal, owner_key: owner_key, scopes: scopes} = verified)
       when not is_nil(principal) and not is_nil(owner_key) and is_list(scopes) do
    expires_at = Map.get(verified, :expires_at)

    decision = %Decision{
      principal: principal,
      owner_key: owner_key,
      scopes: scopes,
      claims: Map.get(verified, :claims, %{}),
      expires_at: expires_at
    }

    if Decision.valid?(decision) and not expired?(expires_at),
      do: {:ok, decision},
      else: :error
  end

  defp decision(_verified), do: :error

  defp expired?(nil), do: false
  defp expired?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt
end
