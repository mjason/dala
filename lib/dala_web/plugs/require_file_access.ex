defmodule DalaWeb.Plugs.RequireFileAccess do
  @moduledoc """
  Gate for `GET /files/raw`. Serves the file when the request is EITHER
  app-authenticated (session cookie, once `load_from_session` has populated
  `:current_user`) OR carries a valid `DalaWeb.FileDownloadToken` for exactly
  the requested path — the token path an MCP `get_download_url` hands out.

  When `DALA_AUTH_ENABLED` is off the whole app is open, so this is a no-op,
  matching `DalaWeb.Plugs.RequireAuth`.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  alias DalaWeb.FileDownloadToken

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    cond do
      not Dala.Auth.enabled?() ->
        conn

      conn.assigns[:current_user] ->
        conn

      token_ok?(conn) ->
        conn

      # A download-link request (carries a token) that didn't pass: a clear
      # 401 for the agent/curl, not an HTML sign-in redirect it can't use.
      is_binary(conn.query_params["token"]) ->
        conn |> send_resp(401, "download token not accepted") |> halt()

      # A plain browser request with an expired/absent session: page redirect,
      # same as the rest of the app.
      true ->
        conn |> redirect(to: "/sign-in") |> halt()
    end
  end

  # A valid signature for the requested path AND the live read capability still
  # granted. Gating on the current `read` flag (not just the signature) means
  # turning MCP read access OFF immediately stops honoring already-minted links
  # — the signature is stateless and otherwise valid for its whole lifetime.
  # The signature check runs first so an invalid token never hits the DB.
  defp token_ok?(conn) do
    token_authorized?(conn) and Dala.Settings.Mcp.terminal_access().read
  end

  defp token_authorized?(conn) do
    with token when is_binary(token) <- conn.query_params["token"],
         path when is_binary(path) <- conn.query_params["path"] do
      FileDownloadToken.valid_for?(token, Dala.Paths.expand_user(path))
    else
      _ -> false
    end
  end
end
