defmodule Dala.Updater do
  @moduledoc """
  In-app self-upgrade against GitHub releases.

  Only active when running from an installed release (`DALA_RELEASE_ROOT`
  points at the `versions/<tag>` + `current` tree that install.sh lays out).
  Applying an update downloads the new tarball next to the current one,
  atomically re-points the `current` symlink (or Windows `current.txt`) and asks
  the platform user-service manager for a restart. Running shells survive inside
  their PTY holders; the service migrates the database before the new version
  boots.
  """
  require Logger

  alias Dala.Updater.Release

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

      {:ok,
       %{
         enabled: enabled?(),
         current: current_version(),
         latest: latest,
         tag: tag,
         update_available: enabled?() and Release.newer?(latest, current_version()),
         notes_url: release["html_url"]
       }}
    end
  end

  @doc "Download the latest release, switch `current` and restart the daemon."
  def apply_latest do
    with :ok <- ensure_enabled(),
         {:ok, release} <- fetch_latest(),
         tag = release["tag_name"],
         :ok <- ensure_newer(tag),
         {:ok, urls} <- Release.verified_asset_urls(release),
         :ok <- install_version(tag, urls.archive, urls.checksum),
         :ok <- switch_current(tag) do
      Logger.info("updater: switched to #{tag}, requesting restart")
      restart()
      {:ok, %{updated_to: tag}}
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

  defp install_version(tag, url, checksum_url) do
    dest = Path.join([release_root(), "versions", tag])
    executable = Path.join(dest, Release.release_executable(Release.platform()))
    staging_id = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    staging = dest <> ".install-#{staging_id}"

    if File.exists?(executable) do
      :ok
    else
      archive = Path.join(System.tmp_dir!(), "dala-#{tag}-#{Path.basename(url)}")

      try do
        with :ok <- download(url, archive),
             {:ok, expected_hash} <- download_checksum(checksum_url),
             {:ok, actual_hash} <- sha256_file(archive),
             :ok <- verify_checksum(expected_hash, actual_hash),
             :ok <- File.mkdir_p(staging),
             :ok <- unpack(archive, staging),
             :ok <- validate_install(staging),
             :ok <- replace_version(staging, dest) do
          :ok
        end
      after
        File.rm(archive)
        File.rm_rf(staging)
      end
    end
  end

  defp validate_install(staging) do
    executable = Path.join(staging, Release.release_executable(Release.platform()))

    if File.regular?(executable),
      do: :ok,
      else:
        {:error, "release archive is missing #{Release.release_executable(Release.platform())}"}
  end

  defp replace_version(staging, dest) do
    with {:ok, _removed} <- File.rm_rf(dest),
         :ok <- File.rename(staging, dest) do
      :ok
    else
      {:error, reason, path} ->
        {:error, "could not replace release at #{path}: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "could not install release: #{inspect(reason)}"}
    end
  end

  defp unpack(archive, dest) do
    result =
      if Release.platform() == "windows-x86_64" do
        :zip.extract(String.to_charlist(archive), cwd: String.to_charlist(dest))
      else
        case System.cmd("tar", ["-xzf", archive, "-C", dest], stderr_to_stdout: true) do
          {_, 0} -> {:ok, []}
          {out, _} -> {:error, String.slice(out, 0, 200)}
        end
      end

    case result do
      {:ok, _files} ->
        :ok

      {:error, reason} ->
        File.rm_rf(dest)
        {:error, "unpack failed: #{inspect(reason)}"}
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

  defp download_checksum(url) do
    case Req.get(url, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} -> Release.checksum_sha256(body)
      {:ok, %{status: status}} -> {:error, "checksum download failed with #{status}"}
      {:error, reason} -> {:error, "checksum download failed: #{Exception.message(reason)}"}
    end
  end

  defp sha256_file(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        hash_file_chunks(file, :crypto.hash_init(:sha256))
      after
        File.close(file)
      end
    end
  end

  defp hash_file_chunks(file, hash) do
    case IO.binread(file, 1_048_576) do
      :eof -> {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, "could not hash release: #{inspect(reason)}"}
      chunk -> hash_file_chunks(file, :crypto.hash_update(hash, chunk))
    end
  end

  defp verify_checksum(hash, hash), do: :ok

  defp verify_checksum(_expected, _actual),
    do: {:error, "SHA-256 checksum mismatch for release archive"}

  # rename(2) over the existing symlink makes the switch atomic.
  defp switch_current(tag) do
    root = release_root()

    if Release.platform() == "windows-x86_64" do
      fresh = Path.join(root, ".current.new")
      current = Path.join(root, "current.txt")

      with :ok <- File.write(fresh, tag <> "\n"),
           :ok <- replace_file(fresh, current) do
        :ok
      else
        {:error, reason} -> {:error, "could not switch current: #{inspect(reason)}"}
      end
    else
      fresh = Path.join(root, ".current.new")
      File.rm(fresh)

      with :ok <- File.ln_s(Path.join([root, "versions", tag]), fresh),
           :ok <- File.rename(fresh, Path.join(root, "current")) do
        :ok
      else
        {:error, reason} -> {:error, "could not switch current: #{inspect(reason)}"}
      end
    end
  end

  defp replace_file(source, destination) do
    case File.rename(source, destination) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :eacces] ->
        replace_windows_file(source, destination)

      error ->
        error
    end
  end

  defp replace_windows_file(source, destination) do
    command = "[IO.File]::Replace($env:DALA_UPDATE_SOURCE, $env:DALA_UPDATE_DESTINATION, $null)"

    case System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command],
           env: [
             {"DALA_UPDATE_SOURCE", source},
             {"DALA_UPDATE_DESTINATION", destination}
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:replace_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:replace_failed, Exception.message(error)}}
  end

  defp restart do
    case Release.platform() do
      "windows-x86_64" ->
        task = System.get_env("DALA_SERVICE", "Dala")
        script = Path.join(:code.priv_dir(:dala), "windows/restart-dala.ps1")
        executable = running_release_executable()

        command =
          "$arguments = '-NoProfile -ExecutionPolicy Bypass -File \"' + " <>
            "$env:DALA_RESTART_SCRIPT + '\" -TaskName \"' + $env:DALA_RESTART_TASK + " <>
            "'\" -StopExecutable \"' + $env:DALA_RESTART_EXECUTABLE + '\"'; " <>
            "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments"

        System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command],
          env: [
            {"DALA_RESTART_SCRIPT", script},
            {"DALA_RESTART_TASK", task},
            {"DALA_RESTART_EXECUTABLE", executable}
          ],
          stderr_to_stdout: true
        )

      "macos-arm64" ->
        service = Application.get_env(:dala, :service_name) || "com.manjialin.dala"
        {uid, 0} = System.cmd("id", ["-u"])

        System.cmd(
          "launchctl",
          ["kickstart", "-k", "gui/#{String.trim(uid)}/#{service}"],
          stderr_to_stdout: true
        )

      _ ->
        service = Application.get_env(:dala, :service_name) || "dala"

        System.cmd("systemctl", ["--user", "restart", "--no-block", service],
          stderr_to_stdout: true
        )
    end
  end

  defp running_release_executable do
    :dala
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("../../../bin/dala.bat")
    |> Path.expand()
  end
end
