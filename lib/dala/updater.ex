defmodule Dala.Updater do
  @moduledoc """
  In-app self-upgrade against GitHub releases.

  Only active when running from an installed release (`DALA_RELEASE_ROOT`
  points at the versioned install tree). Applying an update downloads the new
  archive and hands activation to the platform service lifecycle. Unix swaps
  the `current` symlink; Windows queues the stable out-of-process update helper,
  which atomically replaces `current.txt`, health-checks the new version and
  rolls back on failure. Running shells survive inside their PTY holders.
  """
  require Logger

  alias Dala.Updater.{Release, Status}

  def repo, do: Application.get_env(:dala, :update_repo) || "mjason/dala"

  def release_root do
    case Application.get_env(:dala, :release_root) do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  def enabled?, do: release_root() != nil

  def current_version, do: :dala |> Application.spec(:vsn) |> to_string()

  @doc "Latest release info vs the running version."
  def check do
    with {:ok, release} <- fetch_latest() do
      tag = release["tag_name"] || ""
      latest = String.trim_leading(tag, "v")
      status = Status.read(release_root())

      {:ok,
       %{
         enabled: enabled?(),
         current: current_version(),
         latest: latest,
         tag: tag,
         update_available: enabled?() and Release.newer?(latest, current_version()),
         notes_url: release["html_url"],
         update_state: status && status.state,
         update_message: status && status.message,
         update_version: status && status.version,
         update_updated_at: status && status.updated_at
       }}
    end
  end

  @doc "Download the latest release, activate it and restart the daemon."
  def apply_latest do
    with :ok <- ensure_enabled(),
         {:ok, release} <- fetch_latest(),
         tag = release["tag_name"],
         :ok <- ensure_newer(tag),
         {:ok, url} <- Release.asset_url(release),
         :ok <- install_version(tag, url),
         {:ok, result} <- activate_version(tag) do
      Logger.info("updater: activation pending for #{tag}")
      {:ok, result}
    end
  end

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, "updater is only available on installed releases"}
  end

  defp ensure_newer(tag) do
    if Release.newer?(String.trim_leading(tag || "", "v"), current_version()),
      do: :ok,
      else: {:error, "already up to date (#{current_version()})"}
  end

  # /releases/latest may point at a desktop-client build (see
  # `Dala.Updater.Release.server_release?/1`): list recent releases and pick
  # the newest server one instead.
  defp fetch_latest do
    url = "https://api.github.com/repos/#{repo()}/releases?per_page=15"

    case Req.get(url,
           headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "dala-updater"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        body
        |> Enum.find(&Release.server_release?/1)
        |> case do
          nil -> {:error, "no server releases published yet"}
          release -> {:ok, release}
        end

      {:ok, %{status: 404}} ->
        {:error, "no releases published yet"}

      {:ok, %{status: status}} ->
        {:error, "GitHub responded with #{status}"}

      {:error, reason} ->
        {:error, "could not reach GitHub: #{Exception.message(reason)}"}
    end
  end

  defp install_version(tag, url) do
    dest = Path.join([release_root(), "versions", tag])

    if File.exists?(release_bin(dest)) do
      :ok
    else
      suffix = Path.basename(url)
      archive = Path.join(System.tmp_dir!(), "dala-#{tag}-#{suffix}")

      try do
        with :ok <- download(url, archive) do
          File.mkdir_p!(dest)

          unpack(archive, dest)
        end
      after
        File.rm(archive)
      end
    end
  end

  defp release_bin(dest) do
    suffix = if match?({:win32, :nt}, :os.type()), do: ".bat", else: ""
    Path.join(dest, "bin/dala" <> suffix)
  end

  defp unpack(archive, dest) do
    if String.ends_with?(archive, ".zip") do
      case :zip.unzip(String.to_charlist(archive), cwd: String.to_charlist(dest)) do
        {:ok, _files} ->
          :ok

        {:error, reason} ->
          File.rm_rf(dest)
          {:error, "unpack failed: #{inspect(reason)}"}
      end
    else
      case System.cmd("tar", ["-xzf", archive, "-C", dest], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {out, _} ->
          File.rm_rf(dest)
          {:error, "unpack failed: #{String.slice(out, 0, 200)}"}
      end
    end
  end

  defp download(url, to) do
    Logger.info("updater: downloading #{url}")

    case Req.get(url, into: File.stream!(to), retry: false, receive_timeout: 300_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "download failed with #{status}"}
      {:error, reason} -> {:error, "download failed: #{Exception.message(reason)}"}
    end
  end

  defp activate_version(tag) do
    if match?({:win32, :nt}, :os.type()) do
      queue_windows_activation(tag)
    else
      with :ok <- switch_current(tag),
           :ok <- restart() do
        {:ok, %{state: "pending", target: tag}}
      end
    end
  end

  # rename(2) over the existing symlink makes the Unix switch atomic.
  defp switch_current(tag) do
    root = release_root()
    fresh = Path.join(root, ".current.new")
    File.rm(fresh)

    with :ok <- File.ln_s(Path.join([root, "versions", tag]), fresh),
         :ok <- File.rename(fresh, Path.join(root, "current")) do
      :ok
    else
      {:error, reason} -> {:error, "could not switch current: #{inspect(reason)}"}
    end
  end

  @doc false
  def queue_windows_activation(tag) do
    root = release_root()
    helper = Path.join(root, "update-helper.ps1")
    queue = Path.join(root, "queue-update.ps1")
    request = Path.join(root, ".update-request-#{System.unique_integer([:positive])}.json")
    service = Application.get_env(:dala, :service_name) || "Dala"
    update_task = service <> "-Update"
    port = Application.get_env(:dala, DalaWeb.Endpoint, []) |> get_in([:http, :port]) || 4000

    payload = %{
      installRoot: root,
      targetVersion: tag,
      taskName: service,
      healthUrl: "http://127.0.0.1:#{port}/version"
    }

    with true <- File.regular?(helper) || {:error, "Windows update helper is missing: #{helper}"},
         true <- File.regular?(queue) || {:error, "Windows update queue is missing: #{queue}"},
         :ok <- File.write(request, Jason.encode!(payload)),
         :ok <- Status.write(root, "queued", "Activation queued for #{tag}", tag),
         :ok <- start_windows_helper(queue, helper, request, update_task) do
      # The helper must stop this VM before it can activate the target, so the
      # caller cannot observe the final health result in this request.
      {:ok, %{state: "pending", target: tag}}
    else
      {:error, reason} = error ->
        File.rm(request)
        _ = Status.write(root, "failed", "Could not queue activation: #{inspect(reason)}", tag)
        Logger.error("updater: could not queue Windows activation: #{inspect(reason)}")
        error
    end
  end

  defp start_windows_helper(queue, helper, request, update_task) do
    powershell =
      System.find_executable("powershell.exe") || System.find_executable("powershell") ||
        "powershell.exe"

    case System.cmd(
           powershell,
           [
             "-NoProfile",
             "-NonInteractive",
             "-ExecutionPolicy",
             "Bypass",
             "-File",
             queue,
             "-HelperPath",
             helper,
             "-RequestPath",
             request,
             "-TaskName",
             update_task
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, status} -> {:error, "could not queue Windows update helper (#{status}): #{output}"}
    end
  rescue
    error -> {:error, "could not queue Windows update helper: #{Exception.message(error)}"}
  end

  defp restart do
    case Release.platform() do
      "macos-arm64" ->
        service = Application.get_env(:dala, :service_name) || "com.manjialin.dala"

        with {uid, 0} <- System.cmd("id", ["-u"]),
             {_, 0} <-
               System.cmd(
                 "launchctl",
                 ["kickstart", "-k", "gui/#{String.trim(uid)}/#{service}"],
                 stderr_to_stdout: true
               ) do
          :ok
        else
          {output, status} -> {:error, "launchd restart failed (#{status}): #{output}"}
        end

      _ ->
        service = Application.get_env(:dala, :service_name) || "dala"

        case System.cmd("systemctl", ["--user", "restart", "--no-block", service],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, status} -> {:error, "systemd restart failed (#{status}): #{output}"}
        end
    end
  end
end
