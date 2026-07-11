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
end
