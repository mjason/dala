defmodule Dala.Updater do
  @moduledoc """
  In-app self-upgrade against GitHub releases.

  Only active when running from an installed release (`DALA_RELEASE_ROOT`
  points at the `versions/<tag>` + `current` tree that install.sh lays out).
  Applying an update downloads the new tarball next to the current one,
  atomically re-points the `current` symlink and asks systemd for a restart —
  running shells survive it inside their PTY holders, and the unit's
  ExecStartPre migrates the database before the new version boots.
  """
  require Logger

  @asset_suffix "linux-x86_64.tar.gz"

  def repo, do: System.get_env("DALA_UPDATE_REPO", "mjason/dala")

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
         update_available: enabled?() and newer?(latest, current_version()),
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
         {:ok, url} <- asset_url(release),
         :ok <- install_version(tag, url),
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
    if newer?(String.trim_leading(tag || "", "v"), current_version()),
      do: :ok,
      else: {:error, "already up to date (#{current_version()})"}
  end

  defp newer?(latest, current) do
    match?({:ok, _}, Version.parse(latest)) and
      match?({:ok, _}, Version.parse(current)) and
      Version.compare(latest, current) == :gt
  end

  # Server and desktop-client releases share the repo but use distinct tag
  # prefixes (v* vs client-v*), so /releases/latest may point at a client
  # build. List recent releases and pick the newest server one instead.
  defp fetch_latest do
    url = "https://api.github.com/repos/#{repo()}/releases?per_page=15"

    case Req.get(url,
           headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "dala-updater"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        body
        |> Enum.find(fn release ->
          is_binary(release["tag_name"]) and release["tag_name"] =~ ~r/^v\d/ and
            release["draft"] != true and release["prerelease"] != true
        end)
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

  defp asset_url(%{"assets" => assets, "tag_name" => tag}) when is_list(assets) do
    case Enum.find(assets, &String.ends_with?(&1["name"] || "", @asset_suffix)) do
      %{"browser_download_url" => url} -> {:ok, url}
      _ -> {:error, "release #{tag} has no #{@asset_suffix} asset"}
    end
  end

  defp asset_url(_), do: {:error, "malformed release payload"}

  defp install_version(tag, url) do
    dest = Path.join([release_root(), "versions", tag])

    if File.exists?(Path.join(dest, "bin/dala")) do
      :ok
    else
      tarball = Path.join(System.tmp_dir!(), "dala-#{tag}.tar.gz")

      try do
        with :ok <- download(url, tarball) do
          File.mkdir_p!(dest)

          case System.cmd("tar", ["-xzf", tarball, "-C", dest], stderr_to_stdout: true) do
            {_, 0} ->
              :ok

            {out, _} ->
              File.rm_rf(dest)
              {:error, "unpack failed: #{String.slice(out, 0, 200)}"}
          end
        end
      after
        File.rm(tarball)
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

  # rename(2) over the existing symlink makes the switch atomic.
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

  defp restart do
    service = System.get_env("DALA_SERVICE", "dala")
    System.cmd("systemctl", ["--user", "restart", "--no-block", service], stderr_to_stdout: true)
  end
end
