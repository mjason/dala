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
      {:ok, %File.Stat{type: :regular, size: size}} ->
        disposition = if params["download"] == "1", do: "attachment", else: "inline"
        filename = path |> Path.basename() |> String.replace(~s("), "")

        conn =
          conn
          |> put_resp_content_type(MIME.from_path(path), nil)
          |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
          |> put_resp_header("accept-ranges", "bytes")

        case requested_range(conn, size) do
          :full ->
            send_file(conn, 200, path)

          {:range, first, length} ->
            last = first + length - 1

            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> put_resp_header("content-length", Integer.to_string(length))
            |> send_file(206, path, first, length)

          :invalid ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")
        end

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

  @doc "Runtime upload limits used by browser-side preflight validation."
  def limits(conn, _params) do
    drawer = Dala.FileLimits.drawer_upload_bytes()
    attachment = Dala.FileLimits.browser_attachment_bytes()

    json(conn, %{
      drawer_upload: %{max_bytes: drawer, max_label: Dala.FileLimits.format(drawer)},
      browser_attachment: %{
        max_bytes: attachment,
        max_label: Dala.FileLimits.format(attachment)
      }
    })
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

      upload_size(upload) > Dala.FileLimits.drawer_upload_bytes() ->
        conn
        |> put_status(413)
        |> json(%{
          error:
            "file upload is too large (max #{Dala.FileLimits.format(Dala.FileLimits.drawer_upload_bytes())} per file)"
        })

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

  @doc "Multipart upload for terminal/composer attachments in managed 24-hour storage."
  def attachment(conn, %{"file" => %Plug.Upload{} = upload}) do
    case Dala.Terminal.Attachments.store_upload(upload) do
      {:ok, result} ->
        json(conn, result)

      {:error, message} ->
        status = if String.contains?(message, "too large"), do: 413, else: 400
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  def attachment(conn, _params), do: conn |> put_status(400) |> json(%{error: "missing file"})

  @doc false
  def parse_range(nil, _size), do: :full

  def parse_range("bytes=" <> spec, size) when size > 0 do
    if String.contains?(spec, ",") do
      :invalid
    else
      case String.split(spec, "-", parts: 2) do
        ["", suffix] -> suffix_range(suffix, size)
        [first, ""] -> open_range(first, size)
        [first, last] -> closed_range(first, last, size)
        _ -> :invalid
      end
    end
  end

  def parse_range(_range, _size), do: :invalid

  defp requested_range(conn, size) do
    case get_req_header(conn, "range") do
      [] -> :full
      [range] -> parse_range(String.trim(range), size)
      _multiple -> :invalid
    end
  end

  defp suffix_range(raw, size) do
    with {suffix, ""} when suffix > 0 <- Integer.parse(raw) do
      first = max(size - suffix, 0)
      {:range, first, size - first}
    else
      _ -> :invalid
    end
  end

  defp open_range(raw, size) do
    with {first, ""} when first >= 0 and first < size <- Integer.parse(raw) do
      {:range, first, size - first}
    else
      _ -> :invalid
    end
  end

  defp closed_range(raw_first, raw_last, size) do
    with {first, ""} when first >= 0 and first < size <- Integer.parse(raw_first),
         {last, ""} when last >= first <- Integer.parse(raw_last) do
      last = min(last, size - 1)
      {:range, first, last - first + 1}
    else
      _ -> :invalid
    end
  end

  defp upload_size(%Plug.Upload{path: path}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size
      _ -> Dala.FileLimits.drawer_upload_bytes() + 1
    end
  end

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

  defp expand(path), do: Dala.Paths.expand_user(path)
end
