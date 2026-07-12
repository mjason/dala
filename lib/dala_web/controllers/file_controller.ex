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

  @doc """
  WebSocket: directory-change notifications for the file drawer. The client
  sends {"watch": [dirs]}, the server pushes {"changed": dir}.
  """
  def watch(conn, _params) do
    WebSockAdapter.upgrade(conn, DalaWeb.FileWatchSocket, %{}, timeout: :infinity)
  end

  @doc """
  Multipart upload into a directory (the file manager's upload button and
  drag&drop). Name collisions never overwrite — the upload gets a `-N`
  suffix instead, like a browser download would.
  """
  def upload(conn, %{"dir" => dir, "file" => %Plug.Upload{} = upload}) do
    dir = expand(dir)
    name = upload.filename |> Path.basename() |> String.trim()

    cond do
      not File.dir?(dir) ->
        conn |> put_status(400) |> json(%{error: "not a directory: #{dir}"})

      name == "" or String.contains?(name, ["/", "\0"]) ->
        conn |> put_status(400) |> json(%{error: "invalid file name"})

      true ->
        destination = unique_destination(dir, name)

        case File.cp(upload.path, destination) do
          :ok ->
            %File.Stat{size: size} = File.stat!(destination)
            json(conn, %{path: destination, name: Path.basename(destination), size: size})

          {:error, reason} ->
            conn
            |> put_status(500)
            |> json(%{error: "cannot write #{destination}: #{:file.format_error(reason)}"})
        end
    end
  end

  def upload(conn, _params), do: send_resp(conn, 400, "missing dir or file")

  defp unique_destination(dir, name) do
    candidate = Path.join(dir, name)

    if File.exists?(candidate) do
      extension = Path.extname(name)
      base = Path.basename(name, extension)

      Enum.find_value(1..10_000, candidate, fn n ->
        with_suffix = Path.join(dir, "#{base}-#{n}#{extension}")
        if File.exists?(with_suffix), do: nil, else: with_suffix
      end)
    else
      candidate
    end
  end

  defp expand("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  defp expand(path), do: Path.expand(path)
end
