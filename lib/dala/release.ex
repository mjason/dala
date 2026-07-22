defmodule Dala.Release do
  @moduledoc """
  Tasks that run inside the release, without Mix: `bin/dala eval
  "Dala.Release.migrate()"`. The install/update scripts (and the systemd
  unit's ExecStartPre) call this before every start, so upgrades migrate
  automatically.
  """
  require Logger

  defmodule MetadataReplacementError do
    @moduledoc false
    defexception [:message, recovery: :unknown]
  end

  @app :dala
  @discovery_metadata_key "discoveryFile"

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
  def sync_install_metadata(root_metadata_path, discovery_path, runtime, opts \\ []) do
    discovery_path = Path.expand(discovery_path)

    with_metadata_pair_lock([root_metadata_path, discovery_path], fn ->
      sync_install_metadata_locked(root_metadata_path, discovery_path, runtime, opts)
    end)
  end

  @doc false
  @spec resolve_discovery_file(map(), keyword()) :: String.t()
  def resolve_discovery_file(metadata, opts \\ []) when is_map(metadata) do
    root_metadata_path = Keyword.get(opts, :root_metadata_path)
    env = Keyword.get(opts, :env, System.get_env())

    path =
      case Map.fetch(metadata, @discovery_metadata_key) do
        {:ok, value} -> value
        :error -> Map.get(env, "DALA_DISCOVERY_FILE") || app_data_discovery_file(env)
      end

    canonical_discovery_file!(path, root_metadata_path)
  end

  defp sync_install_metadata_locked(root_metadata_path, discovery_path, runtime, opts) do
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

    discovery_path = canonical_discovery_file!(discovery_path, root_metadata_path)
    validate_metadata_pair_before_sync!(metadata, root_metadata_path, discovery_path)

    updated =
      Map.merge(metadata, %{
        "schemaVersion" => 1,
        "root" => root,
        "dataDir" => required_runtime!(runtime, :data_dir),
        "configFile" => required_runtime!(runtime, :config_file),
        "taskName" => runtime_service_name!(runtime),
        "port" => port,
        "repo" => required_runtime!(runtime, :repo),
        "platform" => "windows-x86_64",
        @discovery_metadata_key => Path.expand(discovery_path)
      })

    body = Jason.encode!(updated, pretty: true) <> "\n"
    write_json_pair_atomic!([{root_metadata_path, body}, {discovery_path, body}], opts)
    :ok
  end

  defp with_metadata_pair_lock(paths, fun) do
    # Windows paths are case-insensitive. Lock each path in a stable order so
    # transactions that share only one metadata file still serialize, while
    # avoiding the lock-order deadlock that nested global locks can otherwise
    # introduce.
    paths =
      paths
      |> Enum.map(&metadata_path_key/1)
      |> Enum.uniq()
      |> Enum.sort()

    with_metadata_path_locks(paths, fun)
  end

  defp with_metadata_path_locks([], fun), do: fun.()

  defp with_metadata_path_locks([path | rest], fun) do
    resource = {__MODULE__, :install_metadata_path, path}

    case :global.trans(
           {resource, self()},
           fn -> with_metadata_path_locks(rest, fun) end,
           [node()],
           :infinity
         ) do
      :aborted ->
        raise "Dala install metadata lock aborted for #{path}"

      {:aborted, reason} ->
        raise "Dala install metadata lock aborted for #{path}: #{inspect(reason)}"

      result ->
        result
    end
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
      metadata =
        root_metadata_path
        |> File.read!()
        |> Jason.decode!()

      discovery_path = resolve_discovery_file(metadata, root_metadata_path: root_metadata_path)

      sync_install_metadata(
        root_metadata_path,
        discovery_path,
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

  defp app_data_discovery_file(env) do
    base =
      case Map.get(env, "APPDATA") do
        value when is_binary(value) and value != "" -> Path.join(value, "Dala")
        _ -> :filename.basedir(:user_config, ~c"Dala") |> List.to_string()
      end

    Path.join(base, "install.json")
  end

  defp canonical_discovery_file!(path, _root_metadata_path) do
    unless is_binary(path) and String.trim(path) != "" do
      raise "Dala discoveryFile is empty or invalid"
    end

    unless Path.type(path) == :absolute do
      raise "Dala discoveryFile must be an absolute path"
    end

    expanded = Path.expand(path)
    ensure_no_symlink_ancestors!(expanded)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :symlink}} ->
        raise "Dala discoveryFile must not be a symbolic link: #{expanded}"

      {:ok, %File.Stat{type: :directory}} ->
        raise "Dala discoveryFile must be a regular file: #{expanded}"

      {:ok, %File.Stat{type: :regular}} ->
        expanded

      {:ok, %File.Stat{type: type}} ->
        raise "Dala discoveryFile must be a regular file: #{expanded} (#{type})"

      {:error, :enoent} ->
        expanded

      {:error, reason} ->
        raise "could not inspect Dala discoveryFile #{expanded}: #{inspect(reason)}"
    end
  end

  defp ensure_no_symlink_ancestors!(path) do
    path
    |> Path.dirname()
    |> do_ensure_no_symlink_ancestors!()
  end

  defp do_ensure_no_symlink_ancestors!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        raise "Dala discoveryFile must not use a symbolic-link ancestor: #{path}"

      {:ok, _stat} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: do_ensure_no_symlink_ancestors!(parent)

      {:error, :enoent} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: do_ensure_no_symlink_ancestors!(parent)

      {:error, reason} ->
        raise "could not inspect Dala discoveryFile ancestor #{path}: #{inspect(reason)}"
    end
  end

  defp validate_metadata_pair_before_sync!(root_metadata, root_metadata_path, discovery_path) do
    root_field = metadata_discovery_field!(root_metadata)

    if root_field != :absent do
      persisted_path = canonical_discovery_file!(root_field, root_metadata_path)

      unless same_path?(persisted_path, discovery_path) do
        raise "Dala root and discovery metadata disagree on discoveryFile"
      end
    end

    case File.read(discovery_path) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "could not read Dala discovery metadata #{discovery_path}: #{inspect(reason)}"

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, discovery_metadata} when is_map(discovery_metadata) ->
            discovery_field = metadata_discovery_field!(discovery_metadata)

            if (root_field == :absent) != (discovery_field == :absent) do
              raise "Dala root and discovery metadata disagree on discoveryFile"
            end

            if root_field != :absent and
                 not same_path?(canonical_discovery_file!(root_field, root_metadata_path),
                   canonical_discovery_file!(discovery_field, root_metadata_path)) do
              raise "Dala root and discovery metadata disagree on discoveryFile"
            end

          {:error, reason} ->
            raise "invalid Dala discovery metadata at #{discovery_path}: #{inspect(reason)}"

          _ ->
            raise "invalid Dala discovery metadata at #{discovery_path}"
        end
    end
  end

  defp metadata_discovery_field!(metadata) when is_map(metadata) do
    case Map.fetch(metadata, @discovery_metadata_key) do
      :error -> :absent

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          raise "Dala discoveryFile metadata field is empty or invalid"
        end

        value

      {:ok, _value} ->
        raise "Dala discoveryFile metadata field is empty or invalid"
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
    metadata_path_key(left) == metadata_path_key(right)
  end

  defp same_path?(_, _), do: false

  defp metadata_path_key(path) do
    expanded = Path.expand(path)

    if match?({:win32, _}, :os.type()) do
      String.downcase(expanded)
    else
      expanded
    end
  end

  # There is no filesystem primitive that atomically replaces two independent
  # files. Stage both payloads first, then replace them while retaining the
  # original bytes. If the second replacement fails, restore every destination
  # that was already changed so a handled failure cannot leave the copies split.
  defp write_json_pair_atomic!(writes, opts) do
    staged = stage_metadata_entries!(writes)
    replace_fun = Keyword.get(opts, :replace_fun, &replace_file!/3)
    cleanup_fun = Keyword.get(opts, :cleanup_fun, &cleanup_windows_backup/1)

    case replace_metadata_entries(staged, replace_fun) do
      {:ok, replaced} ->
        cleanup_metadata_recoveries(replaced, cleanup_fun)
        cleanup_staged_entries(staged)
        :ok

      {:error, error, stacktrace, replaced} ->
        case rollback_metadata_entries(replaced, replace_fun, cleanup_fun) do
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

            backup_text =
              replaced
              |> Enum.flat_map(fn
                %{recovery: {:windows_backup, backup}} -> [backup]
                %{recovery: {:ambiguous_windows_backup, backup}} -> [backup]
                _ -> []
              end)
              |> case do
                [] -> "<none>"
                paths -> Enum.join(paths, ", ")
              end

            raise "Dala install metadata update failed and rollback failed: " <>
                    Exception.message(error) <>
                    " (rollback: #{inspect(rollback_reason)}); " <>
                    "staged metadata retained for recovery: #{retained_text}; " <>
                    "known recovery backups: #{backup_text}"
        end
    end
  end

  defp stage_metadata_entries!(writes) do
    writes = Enum.uniq_by(writes, fn {path, _body} -> metadata_path_key(path) end)

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

  defp replace_metadata_entries(staged, replace_fun) do
    result =
      Enum.reduce_while(staged, [], fn entry, replaced ->
        try do
          recovery = replace_fun.(entry.fresh, entry.path, :commit) |> normalize_recovery!()
          {:cont, [Map.put(entry, :recovery, recovery) | replaced]}
        rescue
          error ->
            # Include the entry whose replacement raised. A platform rename
            # can fail after it has already moved the destination, so omitting
            # it from rollback can leave one metadata copy missing or stale.
            failed = Map.put(entry, :recovery, replacement_error_recovery(error))
            {:halt, {:error, error, __STACKTRACE__, [failed | replaced]}}
        end
      end)

    case result do
      replaced when is_list(replaced) -> {:ok, replaced}
      {:error, _error, _stacktrace, _replaced} = failure -> failure
    end
  end

  defp rollback_metadata_entries(entries, replace_fun, cleanup_fun) do
    errors =
      Enum.reduce(entries, [], fn entry, errors ->
        case restore_metadata_target(entry, replace_fun, cleanup_fun) do
          :ok -> errors
          {:error, reason} -> [reason | errors]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  defp restore_metadata_target(%{path: path, original: :absent} = entry, _replace, cleanup) do
    case File.rm(path) do
      :ok -> cleanup_metadata_recovery(entry.recovery, cleanup)
      {:error, :enoent} -> cleanup_metadata_recovery(entry.recovery, cleanup)
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp restore_metadata_target(
         %{path: path, original: {:regular, _body}, recovery: {:windows_backup, backup}},
         replace_fun,
         cleanup_fun
       ) do
    fresh = metadata_temp_path(path, "rollback")

    try do
      # Never make the only durable old-byte backup the source of a replace:
      # File.Replace can consume its source before reporting failure.
      File.cp!(backup, fresh)
      recovery = replace_fun.(fresh, path, :rollback) |> normalize_recovery!()
      cleanup_metadata_recovery(recovery, cleanup_fun)
      cleanup_metadata_recovery({:windows_backup, backup}, cleanup_fun)
      File.rm(fresh)
      :ok
    rescue
      error ->
        retained = if File.exists?(fresh), do: fresh, else: nil
        {:error, {path, {:known_backup_restore, backup, retained, error}}}
    end
  end

  defp restore_metadata_target(
         %{path: path, original: {:regular, body}} = entry,
         replace_fun,
         cleanup_fun
       ) do
    fresh = metadata_temp_path(path, "rollback")

    try do
      File.write!(fresh, body)
      recovery = replace_fun.(fresh, path, :rollback) |> normalize_recovery!()
      cleanup_metadata_recovery(recovery, cleanup_fun)
      cleanup_metadata_recovery(entry.recovery, cleanup_fun)
      File.rm(fresh)
      :ok
    rescue
      error ->
        retained = retain_snapshot_recovery(path, body, fresh)
        {:error, {path, {:snapshot_restore, retained, error}}}
    end
  end

  defp restore_metadata_target(
         %{path: path, original: {:other, type}} = entry,
         _replace_fun,
         cleanup_fun
       ) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: ^type}} ->
        cleanup_metadata_recovery(entry.recovery, cleanup_fun)

      {:ok, %File.Stat{type: actual}} ->
        {:error, {path, {:cannot_restore_metadata_entry, type, actual}}}

      {:error, reason} ->
        {:error, {path, {:cannot_restore_metadata_entry, type, reason}}}
    end
  end

  defp retain_snapshot_recovery(path, body, fresh) do
    # Always give operators a stable, explicitly named recovery artifact when
    # a restore may have consumed its source. If that copy cannot be written,
    # a complete staged source is still safer than reporting no recovery data.
    retained = metadata_temp_path(path, "rollback-recovery")

    case File.write(retained, body) do
      :ok ->
        retained

      {:error, _reason} ->
        case File.read(fresh) do
          {:ok, ^body} -> fresh
          _ -> nil
        end
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

  defp cleanup_metadata_recoveries(entries, cleanup_fun) do
    Enum.each(entries, &cleanup_metadata_recovery(&1.recovery, cleanup_fun))
  end

  defp cleanup_metadata_recovery(:none, _cleanup_fun), do: :ok
  defp cleanup_metadata_recovery(:unknown, _cleanup_fun), do: :ok

  defp cleanup_metadata_recovery({:ambiguous_windows_backup, backup}, cleanup_fun),
    do: cleanup_metadata_recovery({:windows_backup, backup}, cleanup_fun)

  defp cleanup_metadata_recovery({:windows_backup, backup}, cleanup_fun) do
    case cleanup_fun.(backup) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not remove temporary Dala metadata backup #{backup}: #{inspect(reason)}; " <>
            "leaving it for recovery"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "could not remove temporary Dala metadata backup #{backup}: " <>
          "#{Exception.message(error)}; leaving it for recovery"
      )

      :ok
  end

  defp normalize_recovery!(:none), do: :none

  defp normalize_recovery!({:windows_backup, backup})
       when is_binary(backup) and backup != "",
       do: {:windows_backup, backup}

  defp normalize_recovery!(other),
    do: raise(ArgumentError, "invalid metadata replacement recovery: #{inspect(other)}")

  defp replacement_error_recovery(%MetadataReplacementError{recovery: :none}), do: :none

  defp replacement_error_recovery(%MetadataReplacementError{
         recovery: {:windows_backup, backup}
       })
       when is_binary(backup) and backup != "",
       do: {:windows_backup, backup}

  defp replacement_error_recovery(%MetadataReplacementError{
         recovery: {:ambiguous_windows_backup, backup}
       })
       when is_binary(backup) and backup != "",
       do: {:ambiguous_windows_backup, backup}

  defp replacement_error_recovery(_error), do: :unknown

  defp replace_file!(fresh, path, phase) when phase in [:commit, :rollback] do
    windows? = match?({:win32, _}, :os.type())

    if windows? and phase == :commit do
      ensure_no_windows_backups!(path)
    end

    if windows? and File.exists?(path) do
      # File.Replace rejects a null/empty backup argument on PowerShell. Keep a
      # real recovery path for rollback too; successful replacements clean it
      # through the normal recovery protocol, while failed ones remain
      # inspectable instead of silently losing the destination bytes.
      backup = metadata_temp_path(path, "backup")

      command =
        "[IO.File]::Replace($env:DALA_METADATA_SOURCE, $env:DALA_METADATA_DESTINATION, $env:DALA_METADATA_BACKUP)"

      env =
        [
          {"DALA_METADATA_SOURCE", fresh},
          {"DALA_METADATA_DESTINATION", path},
          {"DALA_METADATA_BACKUP", backup}
        ]

      case System.cmd(
             "powershell.exe",
             ["-NoProfile", "-NonInteractive", "-Command", command],
             env: env,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          {:windows_backup, backup}

        {output, status} ->
          case restore_windows_backup(backup, path) do
            :ok ->
              raise MetadataReplacementError,
                message:
                  "could not replace Dala install metadata (#{status}) #{fresh} -> #{path}: #{output}",
                # Keep the backup durable while the outer pair rollback runs.
                # A failed rollback must still have the original bytes even if
                # this best-effort recovery copy is later consumed.
                recovery: {:windows_backup, backup}

            {:error, reason} ->
              raise MetadataReplacementError,
                message:
                  "could not replace Dala install metadata (#{status}) #{fresh} -> #{path}: #{output}; " <>
                    "backup recovery failed at #{backup}: #{inspect(reason)}",
                recovery: windows_backup_recovery(backup)
          end
      end
    else
      File.rename!(fresh, path)
      :none
    end
  end

  @doc false
  def cleanup_windows_backup(backup) do
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

        :ok
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
            # Copy instead of rename: the outer rollback may consume its
            # source or fail after consuming it, so the generated backup must
            # remain available as the durable recovery copy.
            case File.cp(backup, path) do
              :ok -> :ok
              {:error, reason} -> {:error, {:restore_copy, reason}}
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

  defp windows_backup_recovery(backup) do
    case File.lstat(backup) do
      {:ok, %File.Stat{type: :regular}} -> {:windows_backup, backup}
      _ -> {:ambiguous_windows_backup, backup}
    end
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
