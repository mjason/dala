defmodule DalaWeb.FileController do
  @moduledoc """
  Serves raw file bytes for the file manager: rendered HTML previews, inline
  images and downloads. Behind the same auth gate as the rest of the app —
  and the terminal itself can read any file anyway, so no extra sandboxing
  is attempted.
  """

  use DalaWeb, :controller

  def raw(conn, %{"path" => path} = params) do
    path = expand(path)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        disposition = if params["download"] == "1", do: "attachment", else: "inline"
        filename = path |> Path.basename() |> String.replace(~s("), "")

        conn
        |> put_resp_content_type(MIME.from_path(path), nil)
        |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
        |> send_file(200, path)

      _ ->
        send_resp(conn, 404, "not found")
    end
  end

  def raw(conn, _params), do: send_resp(conn, 400, "missing path")

  defp expand("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  defp expand(path), do: Path.expand(path)
end
