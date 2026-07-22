defmodule Dala.Release do
  @moduledoc """
  Tasks that run inside the release, without Mix: `bin/dala eval
  "Dala.Release.migrate()"`. The install/update scripts (and the systemd
  unit's ExecStartPre) call this before every start, so upgrades migrate
  automatically.
  """
  require Logger

  @app :dala

  def migrate do
    load_app()
    sync_windows_install_metadata()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc false
  def sync_install_metadata(root_metadata_path, discovery_path, runtime) do
    metadata =
      root_metadata_path
      |> File.read!()
      |> Jason.decode!()

    root = required_runtime!(runtime, :root)

    unless same_path?(metadata["root"], root) do
      raise "Dala install metadata root does not match the running release"
    end

    port = Map.fetch!(runtime, :port)

    unless is_integer(port) and port in 1..65_535 do
      raise "Dala runtime port is invalid"
    end

    updated =
      Map.merge(metadata, %{
        "schemaVersion" => 1,
        "root" => root,
        "dataDir" => required_runtime!(runtime, :data_dir),
        "configFile" => required_runtime!(runtime, :config_file),
        "taskName" => runtime_service_name!(runtime),
        "port" => port,
        "repo" => required_runtime!(runtime, :repo),
        "platform" => "windows-x86_64"
      })

    body = Jason.encode!(updated, pretty: true) <> "\n"
    write_json_pair_atomic!([{root_metadata_path, body}, {discovery_path, body}])
    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp sync_windows_install_metadata do
    root = Application.get_env(@app, :release_root)
    root_metadata_path = is_binary(root) && Path.join(root, "install.json")

    if Dala.Updater.Release.platform() == "windows-x86_64" and
         is_binary(root_metadata_path) and File.regular?(root_metadata_path) do
      endpoint = Application.fetch_env!(@app, DalaWeb.Endpoint)
      http = Keyword.fetch!(endpoint, :http)
      port = Keyword.fetch!(http, :port)
      app_data = System.fetch_env!("APPDATA")

      sync_install_metadata(
        root_metadata_path,
        Path.join([app_data, "Dala", "install.json"]),
        %{
          root: root,
          data_dir: Application.fetch_env!(@app, :data_dir),
          config_file: System.fetch_env!("DALA_CONFIG"),
          # The runner and updater both use `Dala` when no custom service name
          # was configured. Keep release metadata in sync with that default.
          task_name: Application.get_env(@app, :service_name) || "Dala",
          port: port,
          repo: Application.fetch_env!(@app, :update_repo)
        }
      )
    end
  end

  defp required_runtime!(runtime, key) do
    case Map.fetch!(runtime, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: raise("Dala runtime #{key} is empty"), else: value

      _ ->
        raise "Dala runtime #{key} is invalid"
    end
  end

  defp runtime_service_name!(runtime) do
    case Map.get(runtime, :task_name) do
      nil -> "Dala"
      _ -> required_runtime!(runtime, :task_name)
    end
  end

  defp same_path?(left, right) when is_binary(left) and is_binary(right) do
    left |> Path.expand() |> String.downcase() == right |> Path.expand() |> String.downcase()
  end

  defp same_path?(_, _), do: false

  # There is no filesystem primitive that atomically replaces two independent
  # files. Stage both payloads first, then replace them while retaining the
  # original bytes. If the second replacement fails, restore every destination
  # that was already changed so a handled failure cannot leave the copies split.
  defp write_json_pair_atomic!(writes) do
    staged = stage_metadata_entries!(writes)

    case replace_metadata_entries(staged) do
      {:ok, _replaced} ->
        cleanup_staged_entries(staged)
        :ok

      {:error, error, stacktrace, replaced} ->
        case rollback_metadata_entries(replaced) do
          :ok ->
            cleanup_staged_entries(staged)
            :erlang.raise(:error, error, stacktrace)

          {:error, rollback_reason} ->
            # Keep any staged bytes that survived the failed replacement. They
            # are the only durable copy of the intended metadata when both the
            # destination and Windows recovery backup are unavailable.
            retained =
              staged
              |> Enum.map(& &1.fresh)
              |> Enum.filter(&File.exists?/1)

            retained_text =
              case retained do
                [] -> "<none>"
                paths -> Enum.join(paths, ", ")
              end

            raise "Dala install metadata update failed and rollback failed: " <>
                    Exception.message(error) <>
                    " (rollback: #{inspect(rollback_reason)}); " <>
                    "staged metadata retained for recovery: #{retained_text}"
        end
    end
  end

  defp stage_metadata_entries!(writes) do
    writes = Enum.uniq_by(writes, fn {path, _body} -> Path.expand(path) end)

    result =
      Enum.reduce_while(writes, [], fn {path, body}, staged ->
        fresh = metadata_temp_path(path, "new")

        try do
          File.mkdir_p!(Path.dirname(path))
          original = snapshot_metadata_target!(path)
          File.write!(fresh, body)

          {:cont, [%{path: path, fresh: fresh, original: original} | staged]}
        rescue
          error ->
            File.rm(fresh)
            {:halt, {:error, error, __STACKTRACE__, staged}}
        end
      end)

    case result do
      staged when is_list(staged) ->
        Enum.reverse(staged)

      {:error, error, stacktrace, staged} ->
        cleanup_staged_entries(staged)
        :erlang.raise(:error, error, stacktrace)
    end
  end

  defp replace_metadata_entries(staged) do
    result =
      Enum.reduce_while(staged, [], fn entry, replaced ->
        try do
          replace_file!(entry.fresh, entry.path)
          {:cont, [entry | replaced]}
        rescue
          error ->
            # Include the entry whose replacement raised. A platform rename
            # can fail after it has already moved the destination, so omitting
            # it from rollback can leave one metadata copy missing or stale.
            {:halt, {:error, error, __STACKTRACE__, [entry | replaced]}}
        end
      end)

    case result do
      replaced when is_list(replaced) -> {:ok, replaced}
      {:error, _error, _stacktrace, _replaced} = failure -> failure
    end
  end

  defp rollback_metadata_entries(entries) do
    errors =
      Enum.reduce(entries, [], fn entry, errors ->
        case restore_metadata_target(entry) do
          :ok -> errors
          {:error, reason} -> [reason | errors]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp restore_metadata_target(%{path: path, original: :absent}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp restore_metadata_target(%{path: path, original: {:regular, body}}) do
    fresh = metadata_temp_path(path, "rollback")

    try do
      File.write!(fresh, body)
      replace_file!(fresh, path)
      :ok
    rescue
      error -> {:error, {path, error}}
    after
      File.rm(fresh)
    end
  end

  defp restore_metadata_target(%{path: path, original: {:other, type}}) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type}} ->
        :ok

      {:ok, %File.Stat{type: actual}} ->
        {:error, {path, {:cannot_restore_metadata_entry, type, actual}}}

      {:error, reason} ->
        {:error, {path, {:cannot_restore_metadata_entry, type, reason}}}
    end
  end

  defp snapshot_metadata_target!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        {:regular, File.read!(path)}

      {:ok, %File.Stat{type: :directory}} ->
        {:other, :directory}

      {:ok, %File.Stat{type: type}} ->
        raise "Dala install metadata target is not a regular file: #{path} (#{type})"

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        raise File.Error, action: "lstat", path: path, reason: reason
    end
  end

  defp metadata_temp_path(path, suffix) do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path <> ".#{suffix}-#{token}"
  end

  defp cleanup_staged_entries(entries) do
    Enum.each(entries, fn entry -> File.rm(entry.fresh) end)
  end

  defp replace_file!(fresh, path) do
    if match?({:win32, _}, :os.type()) do
      ensure_no_windows_backups!(path)
    end

    if match?({:win32, _}, :os.type()) and File.exists?(path) do
      backup = metadata_temp_path(path, "backup")

      command =
        """
        $destination = Get-Item -LiteralPath $env:DALA_METADATA_DESTINATION -Force
        if ($destination.PSIsContainer) { throw 'metadata destination is not a file' }
        Move-Item -LiteralPath $env:DALA_METADATA_DESTINATION -Destination $env:DALA_METADATA_BACKUP -Force
        try {
          Move-Item -LiteralPath $env:DALA_METADATA_SOURCE -Destination $env:DALA_METADATA_DESTINATION -Force
        } catch {
          if (Test-Path -LiteralPath $env:DALA_METADATA_BACKUP) {
            Move-Item -LiteralPath $env:DALA_METADATA_BACKUP -Destination $env:DALA_METADATA_DESTINATION -Force
          }
          throw
        }
        """

      case System.cmd(
             "powershell.exe",
             ["-NoProfile", "-NonInteractive", "-Command", command],
             env: [
               {"DALA_METADATA_SOURCE", fresh},
               {"DALA_METADATA_DESTINATION", path},
               {"DALA_METADATA_BACKUP", backup}
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          case cleanup_windows_backup(backup) do
            :ok ->
              :ok

            {:error, reason} ->
              raise "metadata replacement succeeded but recovery backup remains at #{backup}: " <>
                      inspect(reason)
          end

        {output, status} ->
          case restore_windows_backup(backup, path) do
            :ok ->
              raise "could not replace Dala install metadata (#{status}) #{fresh} -> #{path}: #{output}"

            {:error, reason} ->
              raise "could not replace Dala install metadata (#{status}) #{fresh} -> #{path}: #{output}; " <>
                      "backup recovery failed at #{backup}: #{inspect(reason)}"
          end
      end
    else
      File.rename!(fresh, path)
    end
  end

  defp cleanup_windows_backup(backup) do
    case File.rm(backup) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not remove temporary Dala metadata backup #{backup}: #{inspect(reason)}; " <>
            "leaving it for recovery"
        )

        {:error, reason}
    end
  end

  defp ensure_no_windows_backups!(path) do
    parent = Path.dirname(path)
    leaf = Path.basename(path)
    pattern = Regex.compile!("^" <> Regex.escape(leaf) <> "\\.backup-.+$", "i")

    backups =
      case File.ls(parent) do
        {:ok, names} ->
          names
          |> Enum.filter(&Regex.match?(pattern, &1))
          |> Enum.map(&Path.join(parent, &1))

        {:error, :enoent} ->
          []

        {:error, reason} ->
          raise "could not inspect metadata recovery backups under #{parent}: #{inspect(reason)}"
      end

    case backups do
      [] ->
        :ok

      _ ->
        raise "existing metadata recovery backup requires manual recovery: #{Enum.join(backups, ", ")}"
    end
  end

  defp restore_windows_backup(backup, path) do
    case File.lstat(backup) do
      {:error, :enoent} ->
        case File.lstat(path) do
          {:ok, _destination_stat} -> {:error, :backup_missing_destination_present}
          {:error, :enoent} -> {:error, :backup_missing_and_destination_missing}
          {:error, reason} -> {:error, {:destination_stat, reason}}
        end

      {:ok, %File.Stat{type: :regular}} ->
        case File.lstat(path) do
          {:error, :enoent} ->
            case File.rename(backup, path) do
              :ok -> :ok
              {:error, reason} -> {:error, {:restore_rename, reason}}
            end

          {:ok, _destination_stat} ->
            {:error, :destination_still_exists}

          {:error, reason} ->
            {:error, {:destination_stat, reason}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_backup_type, type}}

      {:error, reason} ->
        {:error, {:backup_stat, reason}}
    end
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
