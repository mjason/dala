defmodule DalaWeb.Plugs.RequireMcp do
  @moduledoc """
  The gate in front of `POST /mcp`. Opt-in and fail-closed. Its state now lives
  in the DB (`Dala.Settings.Mcp`, a global singleton) and is toggled at runtime
  from the web Settings panel — no longer an env var + restart.

    * MCP disabled (the default) → **404**: the endpoint is inert when disabled
      and does nothing else (the route still exists in the router, so this is a
      plain not-found, not true invisibility).
    * enabled but the stored token is blank (defensive — the token is
      server-generated and normally never empty) → **fail closed**: log the
      misconfiguration once and reject every request with **503**. We never open
      an unauthenticated hole.
    * enabled with a token → every request MUST carry
      `Authorization: Bearer <token>`; the presented value is compared with
      `Plug.Crypto.secure_compare/2` (constant time). Missing/malformed/wrong →
      **401**.

  The token is never written to a log or a response body. On success the plug
  assigns `:mcp_authed` and lets the request through to `DalaWeb.McpController`.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Read-only: a disabled/missing singleton must not trigger a DB write on the
    # unauthenticated /mcp path (provisioning happens in the authed :current).
    {enabled, token} = Dala.Settings.Mcp.config_or_default()

    cond do
      not enabled ->
        deny(conn, 404, "not found")

      blank?(token) ->
        log_missing_token_once()
        deny(conn, 503, "mcp is enabled but its token is not set")

      authorized?(conn, token) ->
        assign(conn, :mcp_authed, true)

      true ->
        deny(conn, 401, "unauthorized")
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, token)
      _ -> false
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end

  # "log an error once": a fail-closed install would otherwise log on every
  # single rejected request. Guarded by a process-independent flag so the
  # operator sees it once per boot.
  defp log_missing_token_once do
    key = {__MODULE__, :logged_missing_token}

    if :persistent_term.get(key, false) do
      :ok
    else
      :persistent_term.put(key, true)

      Logger.error(
        "MCP is enabled but its stored token is blank — refusing all /mcp " <>
          "requests (503). Regenerate the token from the Settings panel."
      )
    end
  end
end
