defmodule DalaWeb.McpBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that hands the MCP endpoint its own raw request
  body so `DalaWeb.McpController` can decode JSON itself and answer malformed
  input with a JSON-RPC `-32700` parse error instead of letting `Plug.Parsers`
  raise a bare `400`.

  For `POST /mcp` it reads the whole bounded body, stashes it in
  `conn.private[:mcp_raw_body]`, and returns an EMPTY body to the parser so the
  JSON parser can never raise. `/rpc/run` gets its own bounded text-save
  budget. Every other request is a straight pass-through to
  `Plug.Conn.read_body/2`, so multipart uploads remain streamed by Plug.

  This runs at `Plug.Parsers` (before the router's auth gate), so the buffer is
  hard-capped before buffering: a request over its applicable cap raises
  `Plug.Parsers.RequestTooLargeError` (413) instead of accumulating without
  bound. Without the cap an UNAUTHENTICATED client — even a drive-by web page —
  could stream a huge/infinite body and OOM the BEAM before the gate is reached.
  Unauthenticated MCP bodies remain capped at 1 MB. A request which already
  presents the live MCP bearer token receives a budget derived from the
  configured decoded attachment limit. `/rpc/run` receives a separate budget
  for large text saves. All other request bodies keep Plug's normal limit.
  """

  @mcp_path "/mcp"
  @rpc_path "/rpc/run"
  @unauthenticated_max_body 1_000_000

  @doc "Body reader entry point wired into `Plug.Parsers` in the endpoint."
  def read_body(%Plug.Conn{method: "POST", request_path: @mcp_path} = conn, opts) do
    {max_body, message} =
      if DalaWeb.Plugs.RequireMcp.authenticated?(conn),
        do:
          {Dala.FileLimits.json_request_bytes(@mcp_path),
           Dala.FileLimits.request_too_large_message(@mcp_path)},
        else: {@unauthenticated_max_body, "unauthenticated MCP request is too large (max 1 MB)"}

    reject_known_oversize!(conn, max_body, message)
    opts = Keyword.put(opts, :length, max_body)
    {raw, conn} = read_all(conn, opts, [], 0, max_body, message)
    {:ok, "", Plug.Conn.put_private(conn, :mcp_raw_body, raw)}
  end

  def read_body(%Plug.Conn{method: "POST", request_path: @rpc_path} = conn, opts) do
    max_body = Dala.FileLimits.json_request_bytes(@rpc_path)
    message = Dala.FileLimits.request_too_large_message(@rpc_path)
    reject_known_oversize!(conn, max_body, message)

    case Plug.Conn.read_body(conn, Keyword.put(opts, :length, max_body)) do
      {:more, _chunk, _conn} -> raise DalaWeb.RequestTooLargeError, message: message
      result -> result
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp read_all(conn, opts, chunks, size, max_body, message) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} ->
        cap!(size + byte_size(chunk), max_body, message)
        {IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}

      {:more, chunk, conn} ->
        next_size = size + byte_size(chunk)
        cap!(next_size, max_body, message)
        read_all(conn, opts, [chunk | chunks], next_size, max_body, message)

      {:error, _reason} ->
        {IO.iodata_to_binary(Enum.reverse(chunks)), conn}
    end
  end

  defp cap!(size, max_body, message) when size > max_body,
    do: raise(DalaWeb.RequestTooLargeError, message: message)

  defp cap!(_size, _max_body, _path), do: :ok

  defp reject_known_oversize!(conn, max_body, message) do
    with [raw] <- Plug.Conn.get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(raw),
         true <- length > max_body do
      raise DalaWeb.RequestTooLargeError, message: message
    else
      _ -> :ok
    end
  end
end
