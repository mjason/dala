defmodule DalaWeb.McpBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that hands the MCP endpoint its own raw request
  body so `DalaWeb.McpController` can decode JSON itself and answer malformed
  input with a JSON-RPC `-32700` parse error instead of letting `Plug.Parsers`
  raise a bare `400`.

  For `POST /mcp` it reads the whole (small) body, stashes it in
  `conn.private[:mcp_raw_body]`, and returns an EMPTY body to the parser so the
  JSON parser can never raise. For every other request it is a straight
  pass-through to `Plug.Conn.read_body/2` — no extra buffering, so large
  uploads elsewhere are untouched.

  This runs at `Plug.Parsers` (before the router's auth gate), so the buffer is
  hard-capped before buffering: a request over its applicable cap raises
  `Plug.Parsers.RequestTooLargeError` (413) instead of accumulating without
  bound. Without the cap an UNAUTHENTICATED client — even a drive-by web page —
  could stream a huge/infinite body and OOM the BEAM before the gate is reached.
  Unauthenticated bodies remain capped at 1 MB. A request which already
  presents the live MCP bearer token may use up to 8 MB so one 5 MB decoded
  terminal attachment (about 6.7 MB as base64 plus JSON) can be uploaded.
  """

  @mcp_path "/mcp"
  @unauthenticated_max_body 1_000_000
  @authenticated_max_body 8_000_000

  @doc "Body reader entry point wired into `Plug.Parsers` in the endpoint."
  def read_body(%Plug.Conn{method: "POST", request_path: @mcp_path} = conn, opts) do
    max_body =
      if DalaWeb.Plugs.RequireMcp.authenticated?(conn),
        do: @authenticated_max_body,
        else: @unauthenticated_max_body

    # Read in small chunks so we can stop (and reject) well before a large body
    # is fully materialised, regardless of the caller's :length.
    opts = Keyword.put(opts, :length, max_body)
    {raw, conn} = read_all(conn, opts, "", max_body)
    {:ok, "", Plug.Conn.put_private(conn, :mcp_raw_body, raw)}
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp read_all(conn, opts, acc, max_body) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {cap(acc <> chunk, max_body), conn}
      {:more, chunk, conn} -> read_all(conn, opts, cap(acc <> chunk, max_body), max_body)
      {:error, _reason} -> {acc, conn}
    end
  end

  defp cap(acc, max_body) when byte_size(acc) > max_body,
    do: raise(Plug.Parsers.RequestTooLargeError)

  defp cap(acc, _max_body), do: acc
end
