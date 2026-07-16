defmodule Dala.Terminal.Attachments do
  @moduledoc """
  Bounded storage for files sent through terminal MCP tools or uploaded from
  the browser terminal/composer. Binary content is never written to a PTY;
  callers receive an absolute path which can be pasted into a CLI application.
  """

  use GenServer

  @max_uploads_per_minute 20
  @ttl_seconds 24 * 60 * 60
  @cleanup_interval_ms 60 * 60 * 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def upload(name, mime_type, content_base64) do
    GenServer.call(__MODULE__, {:upload, name, mime_type, content_base64}, 60_000)
  end

  @doc "Store a browser multipart upload without loading its bytes into the BEAM."
  def store_upload(%Plug.Upload{} = upload) do
    GenServer.call(__MODULE__, {:store_upload, upload}, :infinity)
  end

  @doc "Accept only existing regular files, never directories or symlinks."
  def validate_path(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, expanded}

      {:ok, _stat} ->
        {:error, "attachment is not a regular file: #{path}"}

      {:error, reason} ->
        {:error, "cannot access attachment #{path}: #{:file.format_error(reason)}"}
    end
  end

  @impl true
  def init(:ok) do
    root = root()
    _ = ensure_root(root)
    cleanup_expired(root)
    schedule_cleanup()
    {:ok, %{uploads: []}}
  end

  @impl true
  def handle_call({:upload, name, mime_type, content_base64}, _from, state) do
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(state.uploads, &(&1 > now - 60_000))

    if length(recent) >= @max_uploads_per_minute do
      {:reply, {:error, "terminal attachment upload rate limit exceeded"},
       %{state | uploads: recent}}
    else
      reply = persist(name, mime_type, content_base64)
      uploads = if match?({:ok, _}, reply), do: [now | recent], else: recent
      {:reply, reply, %{state | uploads: uploads}}
    end
  end

  def handle_call({:store_upload, upload}, _from, state) do
    {:reply, persist_upload(upload), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired(root())
    schedule_cleanup()
    {:noreply, state}
  end

  defp persist(name, mime_type, content_base64)
       when is_binary(name) and is_binary(content_base64) do
    with :ok <- check_encoded_size(content_base64),
         {:ok, content} <- decode(content_base64),
         :ok <- check_size(content) do
      root = root()
      cleanup_expired(root)

      if ensure_root(root) != :ok do
        {:error, "cannot create terminal attachment storage"}
      else
        persist_content(root, name, mime_type, content)
      end
    end
  end

  defp persist(_name, _mime_type, _content), do: {:error, "name and content_base64 are required"}

  defp persist_upload(%Plug.Upload{path: source, filename: name, content_type: mime_type}) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(source),
         :ok <- check_browser_size(size) do
      root = root()
      cleanup_expired(root)

      if ensure_root(root) != :ok do
        {:error, "cannot create terminal attachment storage"}
      else
        persist_file(root, name, mime_type, size, fn destination ->
          File.cp(source, destination)
        end)
      end
    else
      {:ok, _stat} ->
        {:error, "uploaded attachment is not a regular file"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "cannot access uploaded attachment: #{:file.format_error(reason)}"}
    end
  end

  defp persist_content(root, name, mime_type, content) do
    persist_file(root, name, mime_type, byte_size(content), fn path ->
      File.write(path, content, [:binary])
    end)
  end

  defp persist_file(root, name, mime_type, size, writer) do
    limit = Dala.FileLimits.managed_attachment_bytes()

    if managed_size(root) + size > limit do
      {:error,
       "terminal attachment storage limit exceeded (max #{Dala.FileLimits.format(limit)})"}
    else
      dir = Path.join(root, Ecto.UUID.generate())
      path = Path.join(dir, safe_filename(name, mime_type))

      result =
        with :ok <- File.mkdir_p(dir),
             :ok <- File.chmod(dir, 0o700),
             :ok <- writer.(path),
             :ok <- File.chmod(path, 0o600) do
          {:ok,
           %{
             path: path,
             name: Path.basename(path),
             mime_type: normalize_mime(mime_type),
             size: size,
             expires_in_seconds: @ttl_seconds
           }}
        else
          {:error, reason} ->
            {:error, "cannot store terminal attachment: #{:file.format_error(reason)}"}
        end

      if match?({:error, _}, result), do: File.rm_rf(dir)
      result
    end
  end

  defp decode(content) do
    case Base.decode64(content) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "invalid base64 content"}
    end
  end

  defp check_encoded_size(content) do
    max_encoded = div(Dala.FileLimits.mcp_attachment_bytes() + 2, 3) * 4
    if byte_size(content) <= max_encoded, do: :ok, else: too_large(:mcp)
  end

  defp check_size(content) do
    if byte_size(content) <= Dala.FileLimits.mcp_attachment_bytes(),
      do: :ok,
      else: too_large(:mcp)
  end

  defp check_browser_size(size) do
    if size <= Dala.FileLimits.browser_attachment_bytes(),
      do: :ok,
      else: too_large(:browser)
  end

  defp too_large(:mcp) do
    {:error,
     "terminal attachment is too large (max #{Dala.FileLimits.format(Dala.FileLimits.mcp_attachment_bytes())})"}
  end

  defp too_large(:browser) do
    {:error,
     "terminal attachment is too large (max #{Dala.FileLimits.format(Dala.FileLimits.browser_attachment_bytes())})"}
  end

  defp root do
    :dala
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("tmp/attachments")
  end

  defp ensure_root(root) do
    with :ok <- File.mkdir_p(root), :ok <- File.chmod(root, 0o700), do: :ok
  end

  @doc false
  def cleanup_expired(root, now_seconds \\ System.os_time(:second)) do
    cutoff = now_seconds - @ttl_seconds

    case File.ls(root) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(root, entry)

          case File.lstat(path, time: :posix) do
            {:ok, %File.Stat{type: :directory, mtime: mtime}} when mtime < cutoff ->
              File.rm_rf(path)

            _ ->
              :ok
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)

  defp managed_size(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, total -> total + tree_size(Path.join(root, entry)) end)

      {:error, _reason} ->
        0
    end
  end

  defp tree_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.reduce(entries, 0, &(&2 + tree_size(Path.join(path, &1))))
          {:error, _reason} -> 0
        end

      _ ->
        0
    end
  end

  defp safe_filename(name, mime_type) do
    base =
      name
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("._")
      |> String.slice(0, 100)

    base = if base == "", do: "attachment", else: base

    if Path.extname(base) == "" do
      base <> extension_for(mime_type)
    else
      base
    end
  end

  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/jpeg"), do: ".jpg"
  defp extension_for("image/gif"), do: ".gif"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for("text/plain"), do: ".txt"
  defp extension_for("text/csv"), do: ".csv"
  defp extension_for("application/pdf"), do: ".pdf"
  defp extension_for(_mime_type), do: ".bin"

  defp normalize_mime(value) when is_binary(value) and value != "", do: value
  defp normalize_mime(_value), do: "application/octet-stream"
end
