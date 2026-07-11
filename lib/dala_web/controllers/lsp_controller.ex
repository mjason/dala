defmodule DalaWeb.LspController do
  @moduledoc """
  Upgrades `/lsp/ws` to a WebSocket bridged to a language server process.
  Behind the same auth gate as the rest of the app; like the file manager,
  no path sandboxing beyond that — the terminal can run anything anyway.
  """

  use DalaWeb, :controller

  def ws(conn, %{"root" => root, "path" => path, "server" => server}) do
    with {index, ""} <- Integer.parse(server),
         true <- File.dir?(root) do
      WebSockAdapter.upgrade(
        conn,
        DalaWeb.LspSocket,
        %{root: Path.expand(root), path: path, server: index},
        timeout: :infinity
      )
    else
      _ -> send_resp(conn, 400, "bad lsp request")
    end
  end

  def ws(conn, _params), do: send_resp(conn, 400, "missing root/path/server")

  @doc """
  Bridge registry as JSON: which servers run for which files, traffic
  counters, recent messages, current diagnostics and the stderr tail.
  The editor's debug window reads this — and so can an AI agent:

      curl http://127.0.0.1:4000/lsp/debug
  """
  def debug(conn, _params) do
    json(conn, %{servers: Dala.Lsp.Debug.snapshot()})
  end
end
