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

  alias Dala.Updater.{Archive, Boot, Release}

  @tag_pattern ~r/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
  @max_boot_bytes 8 * 1024 * 1024

  def repo, do: Application.get_env(:dala, :update_repo) || "mjason/dala"

  def release_root do
    case Application.get_env(:dala, :release_root) do
      root when is_binary(root) and root != "" -> root
      _ -> nil
    end
  end

  def enabled?, do: release_root() != nil

  def current_version, do: :dala |> Application.spec(:vsn) |> to_string()

  @doc "Read one update attempt's authoritative helper result."
  def update_result(attempt_id \\ nil)

  def update_result(nil) do
    {:ok, unknown_result(nil)}
  end

  def update_result(attempt_id) when is_binary(attempt_id) do
    case canonical_attempt_id(attempt_id) do
      {:ok, canonical_id} ->
        if enabled?() do
          read_attempt_result(canonical_id)
        else
          {:ok, unknown_result(canonical_id)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def update_result(_attempt_id), do: {:error, "invalid update attempt id"}

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
         {:ok, release} <- fetch_latest() do
      apply_release(release)
    end
  end

  @doc "Apply the exact release observed by a client-correlated update request."
  def apply_latest(attempt_id, expected_target) do
    with :ok <- ensure_enabled(),
         {:ok, attempt_id} <- canonical_attempt_id(attempt_id),
         :ok <- validate_expected_target(expected_target),
         {:ok, previous_tag} <- current_tag(),
         {:ok, attempt} <- begin_update_attempt(attempt_id, expected_target, previous_tag) do
      root = release_root()

      case with_release_lock(root, fn -> apply_expected_release_locked(attempt) end) do
        {:error, "another update is already in progress"} = error ->
          fail_attempt(attempt, error)

        result ->
          result
      end
    end
  end

  @doc false
  def apply_release(release, attempt_id \\ Ecto.UUID.generate()) do
    with :ok <- ensure_enabled(),
         {:ok, attempt_id} <- canonical_attempt_id(attempt_id) do
      root = release_root()
      with_release_lock(root, fn -> apply_release_locked(release, attempt_id) end)
    end
  end

  defp apply_release_locked(release, attempt_id) do
    with tag when is_binary(tag) <- release["tag_name"],
         :ok <- validate_expected_target(tag),
         :ok <- ensure_newer(tag),
         {:ok, previous_tag} <- current_tag(),
         :ok <- ensure_newer_than_installed(tag, previous_tag),
         {:ok, urls} <- Release.verified_asset_urls(release, platform()),
         {:ok, attempt} <- begin_update_attempt(attempt_id, tag, previous_tag) do
      apply_update_attempt(attempt, urls)
    else
      nil -> {:error, "release payload has no tag"}
      error -> error
    end
  end

  defp apply_expected_release_locked(attempt) do
    result =
      with :ok <- ensure_current_tag(attempt.previous),
           {:ok, release} <- fetch_latest(),
           :ok <- ensure_expected_target(release, attempt.target),
           :ok <- ensure_newer(attempt.target),
           :ok <- ensure_newer_than_installed(attempt.target, attempt.previous),
           {:ok, urls} <- Release.verified_asset_urls(release, platform()) do
        {:ready, urls}
      end

    case result do
      {:ready, urls} -> apply_update_attempt(attempt, urls)
      {:error, _reason} = error -> fail_attempt(attempt, error)
    end
  end

  defp ensure_expected_target(%{"tag_name" => expected}, expected), do: :ok

  defp ensure_expected_target(%{"tag_name" => actual}, expected) when is_binary(actual) do
    {:error,
     "latest server release changed from #{expected} to #{actual}; check again before updating"}
  end

  defp ensure_expected_target(_release, expected) do
    {:error, "latest server release changed from #{expected}; check again before updating"}
  end

  defp apply_update_attempt(attempt, urls) do
    result =
      with :ok <- install_version(attempt.target, urls.archive, urls.checksum),
           {:ok, status} <-
             activate_update(attempt.target, attempt.previous, attempt.attempt_id) do
        {:ok, status}
      end

    case result do
      {:ok, status} when status in ["pending", "succeeded"] ->
        if status == "succeeded" do
          _ = complete_attempt(attempt, true, false, "updated to #{attempt.target}")
        end

        {:ok,
         %{
           attempt_id: attempt.attempt_id,
           status: status,
           updated_to: attempt.target
         }}

      {:error, reason, rolled_back} ->
        _ = complete_attempt(attempt, false, rolled_back, to_string(reason))
        {:error, reason}

      {:error, reason} ->
        _ = complete_attempt(attempt, false, false, to_string(reason))
        {:error, reason}
    end
  end

  defp fail_attempt(attempt, {:error, reason} = error) do
    _ = complete_attempt(attempt, false, false, to_string(reason))
    error
  end

  defp with_release_lock(root, fun) do
    resource = {__MODULE__, :apply_release, release_lock_path(root)}

    case :global.trans({resource, self()}, fun, [node()], 0) do
      :aborted -> {:error, "another update is already in progress"}
      result -> result
    end
  end

  defp release_lock_path(root) do
    expanded = Path.expand(root)

    if platform() == "windows-x86_64" or match?({:win32, _}, :os.type()) do
      String.downcase(expanded)
    else
      expanded
    end
  end

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, "updater is only available on installed releases"}
  end

  defp validate_expected_target(target) do
    if valid_tag?(target), do: :ok, else: {:error, "invalid expected update target"}
  end

  defp ensure_newer(tag) do
    if Release.newer?(String.trim_leading(tag || "", "v"), current_version()),
      do: :ok,
      else: {:error, "already up to date (#{current_version()})"}
  end

  defp ensure_newer_than_installed(tag, installed_tag) do
    if Release.newer?(
         String.trim_leading(tag, "v"),
         String.trim_leading(installed_tag, "v")
       ),
       do: :ok,
       else: {:error, "release #{tag} is not newer than installed #{installed_tag}"}
  end

  # /releases/latest may point at a desktop-client build (see
  # `Dala.Updater.Release.server_release?/1`): list recent releases and pick
  # the newest server one instead.
  defp fetch_latest do
    url = "https://api.github.com/repos/#{repo()}/releases?per_page=15"

    options =
      [
        headers: [
          {"accept", "application/vnd.github+json"},
          {"user-agent", "dala-updater"}
        ],
        retry: false
      ]
      |> Keyword.merge(req_options())

    case Req.get(url, options) do
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
    staging_id = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)

    staging =
      if platform() == "windows-x86_64" do
        Path.join(System.tmp_dir!(), "dala-#{tag}.install-#{staging_id}")
      else
        dest <> ".install-#{staging_id}"
      end

    case validate_install(dest, tag) do
      :ok ->
        :ok

      {:error, _reason} ->
        archive =
          Path.join(System.tmp_dir!(), "dala-#{tag}-#{staging_id}-#{Path.basename(url)}")

        try do
          with :ok <- download(url, archive),
               {:ok, expected_hash} <- download_checksum(checksum_url),
               {:ok, actual_hash} <- sha256_file(archive),
               :ok <- verify_checksum(expected_hash, actual_hash),
               :ok <- File.mkdir_p(staging),
               :ok <- unpack(archive, staging),
               :ok <- validate_install(staging, tag),
               :ok <- replace_version(staging, dest, tag),
               :ok <- validate_install(dest, tag) do
            :ok
          end
        after
          File.rm(archive)
          File.rm_rf(staging)
        end
    end
  end

  defp validate_install(root, tag) do
    version = String.trim_leading(tag, "v")
    executable = Release.release_executable(platform())
    app_root = Path.join(root, "lib/dala-#{version}")

    with :ok <- require_release_file(root, executable, "#{executable}"),
         {:ok, erts_version} <- validate_start_erl_data(root, tag, version),
         :ok <- validate_start_boot(root, version),
         :ok <- validate_release_metadata(root, version, erts_version),
         :ok <-
           require_release_file(
             root,
             "erts-#{erts_version}/bin/#{erts_executable()}",
             "ERTS runtime"
           ),
         :ok <- validate_dala_app(app_root, version),
         :ok <- validate_platform_release(root, app_root) do
      :ok
    end
  end

  defp validate_start_erl_data(root, tag, version) do
    path = Path.join(root, "releases/start_erl.data")

    case File.read(path) do
      {:ok, contents} ->
        case String.split(String.trim(contents)) do
          [erts_version, ^version] when erts_version != "" ->
            if valid_erts_version?(erts_version),
              do: {:ok, erts_version},
              else: {:error, "release archive has an invalid ERTS version"}

          _ ->
            {:error, "release archive start_erl.data does not match #{tag}"}
        end

      {:error, _reason} ->
        {:error, "release archive is missing releases/start_erl.data"}
    end
  end

  defp validate_start_boot(root, version) do
    path = Path.join(root, "releases/#{version}/start.boot")

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_boot_bytes ->
        case File.read(path) do
          {:ok, contents} ->
            case Boot.validate(contents, version) do
              :ok -> :ok
              _ -> {:error, "release archive has an invalid releases/#{version}/start.boot"}
            end

          _ ->
            {:error, "release archive has an invalid releases/#{version}/start.boot"}
        end

      {:error, :enoent} ->
        {:error, "release archive is missing releases/#{version}/start.boot"}

      _ ->
        {:error, "release archive has an invalid releases/#{version}/start.boot"}
    end
  end

  defp validate_release_metadata(root, version, erts_version) do
    path = Path.join(root, "releases/#{version}/dala.rel")

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:release, {name, release_version}, {:erts, release_erts}, applications}]}
      when is_list(applications) ->
        valid? =
          release_string(name) == "dala" and
            release_string(release_version) == version and
            release_string(release_erts) == erts_version and
            release_application_version(applications, :dala) == version and
            release_application_version(applications, :kernel) != nil and
            release_application_version(applications, :stdlib) != nil

        if valid?,
          do: :ok,
          else: {:error, "release archive dala.rel does not match #{version}"}

      {:error, :enoent} ->
        {:error, "release archive is missing releases/#{version}/dala.rel"}

      _ ->
        {:error, "release archive has an invalid releases/#{version}/dala.rel"}
    end
  end

  defp release_application_version(applications, name) do
    Enum.find_value(applications, fn
      {^name, version} -> release_string(version)
      {^name, version, _mode} -> release_string(version)
      _ -> nil
    end)
  end

  defp release_string(value) when is_binary(value), do: value

  defp release_string(value) when is_list(value) do
    List.to_string(value)
  rescue
    _error -> nil
  end

  defp release_string(_value), do: nil

  defp validate_dala_app(app_root, version) do
    app_file = Path.join(app_root, "ebin/dala.app")

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, :dala, properties}]} when is_list(properties) ->
        if valid_dala_app?(properties, version),
          do: :ok,
          else: {:error, "release archive dala.app version does not match #{version}"}

      {:error, :enoent} ->
        {:error, "release archive is missing lib/dala-#{version}/ebin/dala.app"}

      _ ->
        {:error, "release archive has an invalid lib/dala-#{version}/ebin/dala.app"}
    end
  end

  defp valid_dala_app?(properties, version) do
    modules = Keyword.get(properties, :modules)
    applications = Keyword.get(properties, :applications)

    app_version(properties) == version and
      is_list(modules) and modules != [] and
      is_list(applications) and :kernel in applications and :stdlib in applications and
      Keyword.get(properties, :mod) == {Dala.Application, []}
  rescue
    _error -> false
  end

  defp app_version(properties) do
    case Keyword.fetch(properties, :vsn) do
      {:ok, version} when is_binary(version) -> version
      {:ok, version} when is_list(version) -> List.to_string(version)
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp validate_platform_release(root, app_root) do
    if platform() == "windows-x86_64" do
      with :ok <- require_release_file(root, "run-dala.ps1", "run-dala.ps1"),
           :ok <-
             require_regular(
               Path.join(app_root, "priv/bin/dala_task_launcher.exe"),
               "release archive is missing Dala task launcher"
             ),
           :ok <-
             require_regular(
               Path.join(app_root, "ebin/Elixir.Dala.beam"),
               "release archive is missing Dala BEAM"
             ),
           :ok <-
             require_regular(
               Path.join(app_root, "priv/windows/update-dala.ps1"),
               "release archive is missing Windows update helper"
             ),
           :ok <-
             require_regular(
               Path.join(app_root, "priv/windows/restart-dala.ps1"),
               "release archive is missing Windows restart helper"
             ),
           :ok <-
             require_regular(
               Path.join(app_root, "priv/windows/publish-dala.ps1"),
               "release archive is missing Windows publish helper"
             ) do
        :ok
      end
    else
      require_regular(
        Path.join(app_root, "priv/unix/update-dala.sh"),
        "release archive is missing Unix update helper"
      )
    end
  end

  defp require_release_file(root, relative, label) do
    require_regular(Path.join(root, relative), "release archive is missing #{label}")
  end

  defp require_regular(path, message) do
    if File.regular?(path), do: :ok, else: {:error, message}
  end

  defp erts_executable do
    if platform() == "windows-x86_64", do: "erl.exe", else: "erl"
  end

  defp valid_erts_version?(version),
    do: Regex.match?(~r/^[0-9A-Za-z][0-9A-Za-z._-]*$/, version)

  defp replace_version(staging, dest, tag) do
    if platform() == "windows-x86_64" and match?({:win32, _}, :os.type()) do
      publish_windows_version(staging, dest, String.trim_leading(tag, "v"))
    else
      replace_version_locally(staging, dest)
    end
  end

  defp publish_windows_version(staging, dest, expected_version) do
    powershell = System.find_executable("powershell.exe") || "powershell.exe"
    script = Path.join(:code.priv_dir(:dala), "windows/publish-dala.ps1")

    System.cmd(
      powershell,
      [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script,
        "-StagingDir",
        staging,
        "-DestinationDir",
        dest,
        "-ExpectedVersion",
        expected_version
      ],
      stderr_to_stdout: true
    )
    |> command_result("could not publish Windows release")
  rescue
    error -> {:error, "could not publish Windows release: #{Exception.message(error)}"}
  end

  defp replace_version_locally(staging, dest) do
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
    with :ok <- Archive.validate(archive, platform()) do
      result =
        if platform() == "windows-x86_64" do
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
  end

  defp download(url, to) do
    Logger.info("updater: downloading #{url}")

    options =
      [into: File.stream!(to), retry: false, receive_timeout: 300_000]
      |> Keyword.merge(req_options())

    case Req.get(url, options) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "download failed with #{status}"}
      {:error, reason} -> {:error, "download failed: #{Exception.message(reason)}"}
    end
  end

  defp download_checksum(url) do
    options = [retry: false, receive_timeout: 30_000] |> Keyword.merge(req_options())

    case Req.get(url, options) do
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
  defp switch_current(tag, expected_tag) do
    with :ok <- ensure_current_tag(expected_tag) do
      do_switch_current(tag)
    end
  end

  defp do_switch_current(tag) do
    root = release_root()

    if platform() == "windows-x86_64" do
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
    if platform() == "windows-x86_64" do
      with :ok <- ensure_no_windows_backups(destination) do
        do_replace_file(source, destination)
      end
    else
      do_replace_file(source, destination)
    end
  end

  defp do_replace_file(source, destination) do
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
    backup =
      destination <> ".backup-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    command =
      "[IO.File]::Replace($env:DALA_UPDATE_SOURCE, $env:DALA_UPDATE_DESTINATION, $env:DALA_UPDATE_BACKUP)"

    case System.cmd(
           "powershell.exe",
           ["-NoProfile", "-NonInteractive", "-Command", command],
           env: [
             {"DALA_UPDATE_SOURCE", source},
             {"DALA_UPDATE_DESTINATION", destination},
             {"DALA_UPDATE_BACKUP", backup}
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        case cleanup_windows_backup(backup) do
          :ok ->
            :ok

          {:error, reason} ->
            # File.Replace has already committed the new destination. Treat
            # cleanup of the old-byte recovery copy as non-transactional so a
            # successful pointer write cannot trigger a rollback; leave the
            # backup in place for manual recovery.
            Logger.warning(
              "updater: replacement committed but temporary backup remains at #{backup}: " <>
                "#{inspect(reason)}"
            )

            :ok
        end

      {output, status} ->
        case restore_windows_backup(backup, destination) do
          :ok ->
            {:error, {:replace_failed, status, String.trim(output)}}

          {:error, restore_reason} ->
            {:error,
             {:replace_failed, status, String.trim(output), {:backup_restore, restore_reason}}}
        end
    end
  rescue
    error -> {:error, {:replace_failed, Exception.message(error)}}
  end

  defp cleanup_windows_backup(backup) do
    case File.rm(backup) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_no_windows_backups(path) do
    parent = Path.dirname(path)
    leaf = Path.basename(path)
    pattern = Regex.compile!("^" <> Regex.escape(leaf) <> "\\.backup-.+$", "i")

    case File.ls(parent) do
      {:ok, names} ->
        case Enum.find(names, &Regex.match?(pattern, &1)) do
          nil -> :ok
          backup -> {:error, {:orphan_recovery_backup, Path.join(parent, backup)}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:backup_directory_unreadable, parent, reason}}
    end
  end

  defp restore_windows_backup(backup, destination) do
    case File.lstat(backup) do
      {:error, :enoent} ->
        case File.lstat(destination) do
          {:ok, _destination_stat} -> {:error, :backup_missing_destination_present}
          {:error, :enoent} -> {:error, :backup_missing_and_destination_missing}
          {:error, reason} -> {:error, {:destination_stat, reason}}
        end

      {:ok, %File.Stat{type: :regular}} ->
        case File.lstat(destination) do
          {:error, :enoent} ->
            case File.rename(backup, destination) do
              :ok -> :ok
              {:error, reason} -> {:error, {:rename, reason, backup}}
            end

          {:ok, _destination_stat} ->
            {:error, {:destination_still_exists, backup}}

          {:error, reason} ->
            {:error, {:destination_stat, reason, backup}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_backup_type, type, backup}}

      {:error, reason} ->
        {:error, {:backup_stat, reason, backup}}
    end
  end

  defp activate_update(tag, previous_tag, attempt_id) do
    expected_version = String.trim_leading(tag, "v")

    result =
      cond do
        platform() == "windows-x86_64" ->
          with :ok <- ensure_current_tag(previous_tag),
               :ok <- restart(tag, previous_tag, expected_version, attempt_id) do
            Logger.info("updater: staged #{tag}, scheduled detached switch from #{previous_tag}")
            {:ok, "pending"}
          end

        is_function(Application.get_env(:dala, :updater_restart), 3) ->
          activate_with_test_restart(tag, previous_tag, expected_version, attempt_id)

        true ->
          with :ok <- ensure_current_tag(previous_tag),
               :ok <- schedule_unix_update(tag, previous_tag, expected_version, attempt_id) do
            Logger.info("updater: staged #{tag}, scheduled verified Unix activation")
            {:ok, "pending"}
          end
      end

    normalize_current_change(result)
  end

  defp activate_with_test_restart(tag, previous_tag, expected_version, attempt_id) do
    with :ok <- switch_current(tag, previous_tag) do
      case restart(tag, previous_tag, expected_version, attempt_id) do
        :ok -> {:ok, "succeeded"}
        {:error, reason} -> rollback_current(previous_tag, tag, reason, attempt_id)
      end
    end
  end

  defp rollback_current(previous_tag, failed_tag, reason, attempt_id) do
    Logger.error("updater: restart for #{failed_tag} failed, rolling back to #{previous_tag}")

    case switch_current(previous_tag, failed_tag) do
      :ok ->
        case restart(
               previous_tag,
               failed_tag,
               String.trim_leading(previous_tag, "v"),
               attempt_id
             ) do
          :ok ->
            {:error, reason, true}

          {:error, rollback_reason} ->
            {:error, "#{reason}; rollback restart failed: #{rollback_reason}", false}
        end

      {:error, {:current_release_changed, expected, actual}} ->
        {:error, "#{reason}; rollback skipped: #{current_change_message(expected, actual)}",
         false}

      {:error, rollback_reason} ->
        {:error, "#{reason}; rollback failed: #{inspect(rollback_reason)}", false}
    end
  end

  defp restart(tag, previous_tag, expected_version, attempt_id) do
    try do
      run_restart(tag, previous_tag, expected_version, attempt_id)
    rescue
      error -> {:error, "service restart raised: #{Exception.message(error)}"}
    catch
      :throw, reason -> {:error, "service restart threw: #{inspect(reason)}"}
      :exit, reason -> {:error, "service restart exited: #{inspect(reason)}"}
    end
  end

  defp run_restart(tag, previous_tag, expected_version, attempt_id) do
    case Application.get_env(:dala, :updater_restart) do
      fun when is_function(fun, 3) ->
        fun.(tag, previous_tag, expected_version)

      _ ->
        restart_platform(tag, previous_tag, expected_version, attempt_id)
    end
  end

  defp restart_platform(tag, previous_tag, expected_version, attempt_id) do
    case platform() do
      "windows-x86_64" ->
        schedule_windows_update(tag, previous_tag, expected_version, attempt_id)

      _ ->
        {:error, "direct Unix restart is not an authoritative update path"}
    end
  end

  defp schedule_unix_update(tag, previous_tag, expected_version, attempt_id) do
    script = Path.join(:code.priv_dir(:dala), "unix/update-dala.sh")
    result_file = attempt_result_path(attempt_id)
    log_file = Path.join([release_root(), "logs", "update-#{attempt_id}.log"])
    service_manager = if platform() == "macos-arm64", do: "launchd", else: "systemd"
    default_service = if service_manager == "launchd", do: "com.manjialin.dala", else: "dala"
    service = Application.get_env(:dala, :service_name) || default_service
    health_url = updater_health_url()

    with true <- File.regular?(script),
         :ok <- File.mkdir_p(Path.dirname(log_file)) do
      command = ~s(nohup "$@" >> "$DALA_UPDATE_LOG" 2>&1 </dev/null &)

      System.cmd(
        "/bin/sh",
        [
          "-c",
          command,
          "dala-update",
          "/bin/sh",
          script,
          release_root(),
          service_manager,
          service,
          tag,
          previous_tag,
          expected_version,
          String.trim_leading(previous_tag, "v"),
          attempt_id,
          result_file,
          health_url,
          "60",
          "0.5"
        ],
        env: [{"DALA_UPDATE_LOG", log_file}],
        stderr_to_stdout: true
      )
      |> command_result("could not launch detached Unix update helper")
    else
      false -> {:error, "release is missing the Unix update helper"}
      {:error, reason} -> {:error, "could not prepare Unix update helper: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "could not launch detached Unix update helper: #{Exception.message(error)}"}
  end

  defp updater_health_url do
    case Application.get_env(:dala, :updater_health_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        http = Application.get_env(:dala, DalaWeb.Endpoint, []) |> Keyword.get(:http, [])
        port = Keyword.get(http, :port, 4000)
        ip = Keyword.get(http, :ip, {127, 0, 0, 1})
        "http://#{health_host(ip)}:#{port}/version"
    end
  end

  defp health_host({0, 0, 0, 0}), do: "127.0.0.1"
  defp health_host({0, 0, 0, 0, 0, 0, 0, 0}), do: "[::1]"

  defp health_host(ip) when is_tuple(ip) do
    address = ip |> :inet.ntoa() |> to_string()
    if tuple_size(ip) == 8, do: "[#{address}]", else: address
  end

  defp health_host(_ip), do: "127.0.0.1"

  defp schedule_windows_update(tag, previous_tag, expected_version, attempt_id) do
    powershell = System.find_executable("powershell.exe") || "powershell.exe"
    task = Application.get_env(:dala, :service_name) || "Dala"
    script = Path.join(:code.priv_dir(:dala), "windows/update-dala.ps1")
    result_file = attempt_result_path(attempt_id)

    payload =
      %{
        script: script,
        install_root: release_root(),
        task_name: task,
        target_tag: tag,
        previous_tag: previous_tag,
        expected_version: expected_version,
        previous_version: String.trim_leading(previous_tag, "v"),
        attempt_id: attempt_id,
        result_file: result_file
      }
      |> Jason.encode!()
      |> Base.encode64()

    detached_script = """
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('#{payload}')) | ConvertFrom-Json
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $payload.script `
      -InstallRoot $payload.install_root -TaskName $payload.task_name `
      -TargetTag $payload.target_tag -PreviousTag $payload.previous_tag `
      -ExpectedVersion $payload.expected_version -PreviousVersion $payload.previous_version `
      -AttemptId $payload.attempt_id -ResultFile $payload.result_file -DelayMilliseconds 750
    exit $LASTEXITCODE
    """

    encoded =
      detached_script
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    command_line = ~s("#{powershell}" -NoProfile -NonInteractive -EncodedCommand #{encoded})

    launcher = """
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$env:DALA_UPDATE_COMMAND}
    if ($result.ReturnValue -ne 0) {
      Write-Error "Win32_Process.Create failed with code $($result.ReturnValue)"
      exit 1
    }
    """

    System.cmd(powershell, ["-NoProfile", "-NonInteractive", "-Command", launcher],
      env: [{"DALA_UPDATE_COMMAND", command_line}],
      stderr_to_stdout: true
    )
    |> command_result("could not launch detached Windows update helper")
  rescue
    error ->
      {:error, "could not launch detached Windows update helper: #{Exception.message(error)}"}
  end

  defp current_tag do
    root = release_root()

    result =
      if platform() == "windows-x86_64" do
        File.read(Path.join(root, "current.txt"))
      else
        case File.read_link(Path.join(root, "current")) do
          {:ok, target} -> {:ok, Path.basename(target)}
          error -> error
        end
      end

    case result do
      {:ok, tag} ->
        tag = String.trim(tag)

        if Regex.match?(@tag_pattern, tag),
          do: {:ok, tag},
          else: {:error, "installed release has an invalid current version pointer"}

      {:error, reason} ->
        {:error, "could not read current release pointer: #{inspect(reason)}"}
    end
  end

  defp ensure_current_tag(expected) do
    case current_tag() do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:current_release_changed, expected, actual}}
      error -> error
    end
  end

  defp normalize_current_change({:error, {:current_release_changed, expected, actual}}),
    do: {:error, current_change_message(expected, actual)}

  defp normalize_current_change(result), do: result

  defp current_change_message(expected, actual),
    do: "current release changed from #{expected} to #{actual} during update"

  defp begin_update_attempt(attempt_id, target, previous) do
    attempt = %{
      attempt_id: attempt_id,
      target: target,
      previous: previous,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    pending = %{
      attempt_id: attempt.attempt_id,
      status: "pending",
      target: target,
      previous: previous,
      started_at: attempt.started_at
    }

    with :ok <- File.mkdir_p(attempt_results_dir()),
         :ok <- reserve_attempt_result(attempt.attempt_id, pending) do
      {:ok, attempt}
    else
      {:error, reason} -> {:error, "could not create update attempt: #{inspect(reason)}"}
    end
  end

  defp reserve_attempt_result(attempt_id, pending) do
    File.write(attempt_result_path(attempt_id), Jason.encode!(pending) <> "\n", [
      :binary,
      :exclusive
    ])
  end

  defp complete_attempt(attempt, success, rolled_back, message) do
    result = %{
      attempt_id: attempt.attempt_id,
      success: success,
      rolled_back: rolled_back,
      target: attempt.target,
      previous: attempt.previous,
      message: message,
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case write_json_atomic(attempt_result_path(attempt.attempt_id), result) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("updater: could not write attempt result: #{inspect(reason)}")
        error
    end
  end

  defp read_attempt_result(attempt_id) do
    result =
      with {:ok, contents} <- File.read(attempt_result_path(attempt_id)),
           {:ok, payload} <- Jason.decode(contents) do
        normalize_attempt_result(payload, attempt_id)
      else
        _ -> unknown_result(attempt_id)
      end

    {:ok, result}
  end

  defp normalize_attempt_result(payload, attempt_id) do
    cond do
      exact_keys?(payload, ["attempt_id", "previous", "started_at", "status", "target"]) ->
        normalize_pending_result(payload, attempt_id)

      exact_keys?(payload, [
        "attempt_id",
        "completed_at",
        "message",
        "previous",
        "rolled_back",
        "success",
        "target"
      ]) ->
        normalize_final_result(payload, attempt_id)

      true ->
        unknown_result(attempt_id)
    end
  end

  defp normalize_pending_result(
         %{
           "attempt_id" => attempt_id,
           "previous" => previous,
           "started_at" => started_at,
           "status" => "pending",
           "target" => target
         },
         attempt_id
       ) do
    if valid_tag?(target) and valid_tag?(previous) and valid_datetime?(started_at) do
      %{
        attempt_id: attempt_id,
        status: "pending",
        target: target,
        message: nil,
        rolled_back: nil,
        started_at: started_at,
        completed_at: nil
      }
    else
      unknown_result(attempt_id)
    end
  end

  defp normalize_pending_result(_payload, attempt_id), do: unknown_result(attempt_id)

  defp normalize_final_result(
         %{
           "attempt_id" => attempt_id,
           "completed_at" => completed_at,
           "message" => message,
           "previous" => previous,
           "rolled_back" => rolled_back,
           "success" => success,
           "target" => target
         },
         attempt_id
       )
       when is_boolean(success) and is_boolean(rolled_back) and is_binary(message) do
    if valid_tag?(target) and valid_tag?(previous) and valid_datetime?(completed_at) do
      %{
        attempt_id: attempt_id,
        status: if(success, do: "succeeded", else: "failed"),
        target: target,
        message: message,
        rolled_back: rolled_back,
        started_at: nil,
        completed_at: completed_at
      }
    else
      unknown_result(attempt_id)
    end
  end

  defp normalize_final_result(_payload, attempt_id), do: unknown_result(attempt_id)

  defp unknown_result(attempt_id) do
    %{
      attempt_id: attempt_id,
      status: "unknown",
      target: nil,
      message: nil,
      rolled_back: nil,
      started_at: nil,
      completed_at: nil
    }
  end

  defp attempt_results_dir, do: Path.join([release_root(), "logs", "update-results"])

  defp attempt_result_path(attempt_id),
    do: Path.join(attempt_results_dir(), "#{attempt_id}.json")

  defp write_json_atomic(path, payload) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      fresh = path <> ".new-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      case File.write(fresh, Jason.encode!(payload) <> "\n", [:binary]) do
        :ok ->
          case replace_file(fresh, path) do
            :ok ->
              File.rm(fresh)
              :ok

            {:error, reason} = error ->
              # A failed Windows replacement can have consumed the source or
              # left destination/backup state ambiguous. Do not erase the
              # staged result unconditionally; it may be the only recoverable
              # copy left for an operator.
              if File.exists?(fresh) do
                Logger.error(
                  "updater: replacement failed; staged attempt result retained at #{fresh}: " <>
                    "#{inspect(reason)}"
                )
              else
                Logger.error(
                  "updater: replacement failed after consuming staged result: #{inspect(reason)}"
                )
              end

              error

            other ->
              other
          end

        {:error, _reason} = error ->
          File.rm(fresh)
          error
      end
    end
  end

  defp exact_keys?(value, keys) when is_map(value), do: Enum.sort(Map.keys(value)) == keys
  defp exact_keys?(_value, _keys), do: false

  defp valid_tag?(tag) when is_binary(tag), do: Regex.match?(@tag_pattern, tag)
  defp valid_tag?(_tag), do: false

  defp canonical_attempt_id(attempt_id) when is_binary(attempt_id) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, ^attempt_id} -> {:ok, attempt_id}
      _ -> {:error, "invalid update attempt id"}
    end
  end

  defp canonical_attempt_id(_attempt_id), do: {:error, "invalid update attempt id"}

  defp valid_datetime?(value), do: match?({:ok, _datetime}, parse_datetime(value))

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp platform, do: Application.get_env(:dala, :updater_platform) || Release.platform()
  defp req_options, do: Application.get_env(:dala, :updater_req_options, [])

  defp command_result(result, prefix)
  defp command_result({_output, 0}, _prefix), do: :ok

  defp command_result({output, status}, prefix),
    do: {:error, "#{prefix} (exit #{status}): #{String.trim(output)}"}
end
