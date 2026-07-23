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
  @windows_reserved_path_basenames ~w(CON PRN AUX NUL CONIN$ CONOUT$ CLOCK$ COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9 LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9)
  @windows_reserved_superscript_basenames for prefix <- ~w(COM LPT),
                                              suffix <- [
                                                <<0xC2, 0xB9>>,
                                                <<0xC2, 0xB2>>,
                                                <<0xC2, 0xB3>>
                                              ],
                                              do: prefix <> suffix
  @windows_forbidden_path_bytes Enum.to_list(0..31) ++ ~c"<>\"|?*"

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
    root_metadata_path = canonical_root_metadata_path!(root_metadata_path)
    discovery_path = canonical_discovery_file!(discovery_path, root_metadata_path)

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
      case metadata_discovery_field!(metadata) do
        value when is_binary(value) ->
          value

        :absent ->
          case Map.get(env, "DALA_DISCOVERY_FILE") do
            value when is_binary(value) and byte_size(value) > 0 ->
              if String.trim(value) == "", do: app_data_discovery_file(env), else: value

            _ ->
              app_data_discovery_file(env)
          end
      end

    canonical_discovery_file!(path, root_metadata_path)
  end

  defp sync_install_metadata_locked(root_metadata_path, discovery_path, runtime, opts) do
    metadata = read_root_metadata!(root_metadata_path)

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
        @discovery_metadata_key => discovery_path
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

    root_metadata_path =
      if is_binary(root),
        do: canonical_root_metadata_path!(Path.join(root, "install.json"))

    if Dala.Updater.Release.platform() == "windows-x86_64" and is_binary(root_metadata_path) and
         regular_metadata_target?(root_metadata_path) do
      endpoint = Application.fetch_env!(@app, DalaWeb.Endpoint)
      http = Keyword.fetch!(endpoint, :http)
      port = Keyword.fetch!(http, :port)

      metadata = read_root_metadata!(root_metadata_path)

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
        value when is_binary(value) ->
          if String.trim(value) == "",
            do: fallback_user_config_dir(),
            else: Path.join(value, "Dala")

        _ ->
          :filename.basedir(:user_config, ~c"Dala") |> List.to_string()
      end

    Path.join(base, "install.json")
  end

  defp fallback_user_config_dir, do: :filename.basedir(:user_config, ~c"Dala") |> List.to_string()

  defp canonical_root_metadata_path!(path) do
    unless is_binary(path) and String.trim(path) != "" do
      raise "Dala root install metadata path is empty or invalid"
    end

    unless Path.type(path) == :absolute do
      raise "Dala root install metadata path must be absolute"
    end

    if windows?() and invalid_windows_metadata_path?(path) do
      raise "Dala root install metadata path must be a normal Windows path"
    end

    expanded = expand_metadata_path(path)

    if String.downcase(Path.basename(expanded)) != "install.json" do
      raise "Dala root metadata must name install.json"
    end

    expanded
  end

  defp regular_metadata_target?(path) do
    ensure_safe_metadata_target!(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        true

      {:error, :enoent} ->
        false

      {:ok, %File.Stat{type: type}} ->
        raise "Dala root install metadata must be a regular file: #{path} (#{type})"

      {:error, reason} ->
        raise "could not inspect Dala root install metadata #{path}: #{inspect(reason)}"
    end
  end

  defp read_root_metadata!(path) do
    unless regular_metadata_target?(path) do
      raise "Dala root install metadata is missing: #{path}"
    end

    case File.read(path) do
      {:ok, body} ->
        Jason.decode!(body)

      {:error, reason} ->
        raise "could not read Dala root install metadata #{path}: #{inspect(reason)}"
    end
  end

  defp canonical_discovery_file!(path, _root_metadata_path) do
    unless is_binary(path) and String.trim(path) != "" do
      raise "Dala discoveryFile is empty or invalid"
    end

    unless Path.type(path) == :absolute do
      raise "Dala discoveryFile must be an absolute path"
    end

    if windows?() and invalid_windows_metadata_path?(path) do
      raise "Dala discoveryFile must be a normal Windows path"
    end

    expanded = expand_metadata_path(path)

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

  defp ensure_safe_metadata_target!(path) do
    ensure_no_symlink_ancestors!(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        raise "Dala install metadata target must not be a symbolic link: #{path}"

      {:ok, %File.Stat{type: :directory}} ->
        raise "Dala install metadata target must be a regular file: #{path}"

      {:ok, %File.Stat{type: type}} ->
        raise "Dala install metadata target must be a regular file: #{path} (#{type})"

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "could not inspect Dala install metadata target #{path}: #{inspect(reason)}"
    end
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
            unless same_path?(discovery_metadata["root"], root_metadata["root"]) do
              raise "Dala root and discovery metadata disagree on root"
            end

            discovery_field = metadata_discovery_field!(discovery_metadata)

            if root_field == :absent != (discovery_field == :absent) do
              raise "Dala root and discovery metadata disagree on discoveryFile"
            end

            if root_field != :absent and
                 not same_path?(
                   canonical_discovery_file!(root_field, root_metadata_path),
                   canonical_discovery_file!(discovery_field, root_metadata_path)
                 ) do
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
    keys =
      metadata
      |> Map.keys()
      |> Enum.filter(fn key ->
        is_binary(key) and String.downcase(key) == String.downcase(@discovery_metadata_key)
      end)

    case keys do
      [] ->
        :absent

      [@discovery_metadata_key] ->
        value = Map.fetch!(metadata, @discovery_metadata_key)

        unless is_binary(value) do
          raise "Dala discoveryFile metadata field is empty or invalid"
        end

        if String.trim(value) == "" do
          raise "Dala discoveryFile metadata field is empty or invalid"
        end

        value

      _ ->
        raise "Dala discoveryFile metadata field has invalid casing"
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
    expanded =
      if windows?() and is_binary(path) and normal_windows_discovery_root?(path) do
        expand_metadata_path(path)
      else
        Path.expand(path)
      end

    if match?({:win32, _}, :os.type()) do
      Dala.Paths.comparison_key_for_os(expanded, {:win32, :nt})
    else
      expanded
    end
  end

  defp invalid_windows_metadata_path?(path) do
    not String.valid?(path) or
      not normal_windows_discovery_root?(path) or
      String.starts_with?(path, ["\\\\?\\", "\\\\.\\"]) or
      String.ends_with?(path, ["\\", "/"]) or
      (byte_size(path) > 2 and String.contains?(binary_part(path, 2, byte_size(path) - 2), ":")) or
      invalid_windows_metadata_segments?(path)
  end

  defp invalid_windows_metadata_segments?(<<drive, ?:, separator, rest::binary>>)
       when (drive in ?A..?Z or drive in ?a..?z) and separator in [?\\, ?/] do
    rest |> windows_path_segments() |> Enum.any?(&invalid_windows_metadata_segment?/1)
  end

  defp invalid_windows_metadata_segments?(<<?\\, ?\\, rest::binary>>) do
    case windows_path_segments(rest) do
      [server, share, _file | _rest] = segments ->
        invalid_windows_path_segment?(server) or
          invalid_windows_path_segment?(share) or
          segments |> Enum.drop(2) |> Enum.any?(&invalid_windows_metadata_segment?/1)

      _incomplete_unc ->
        true
    end
  end

  defp invalid_windows_metadata_segments?(_path), do: true

  defp windows_path_segments(path) do
    path |> String.replace("\\", "/") |> String.split("/", trim: false)
  end

  defp invalid_windows_metadata_segment?(segment) do
    basename =
      segment
      |> String.split(".", parts: 2)
      |> hd()
      |> trim_windows_ignored_suffix()
      |> String.upcase()

    invalid_windows_path_segment?(segment) or
      basename in @windows_reserved_path_basenames or
      basename in @windows_reserved_superscript_basenames
  end

  defp invalid_windows_path_segment?(segment) do
    segment == "" or
      String.ends_with?(segment, [".", " "]) or
      Enum.any?(:binary.bin_to_list(segment), &(&1 in @windows_forbidden_path_bytes))
  end

  defp trim_windows_ignored_suffix(""), do: ""

  defp trim_windows_ignored_suffix(segment) do
    if :binary.last(segment) in [?., ?\s] do
      segment
      |> binary_part(0, byte_size(segment) - 1)
      |> trim_windows_ignored_suffix()
    else
      segment
    end
  end

  defp normal_windows_discovery_root?(<<drive, ?:, separator, _::binary>>)
       when drive in ?A..?Z and separator in [?\\, ?/],
       do: true

  defp normal_windows_discovery_root?(<<drive, ?:, separator, _::binary>>)
       when drive in ?a..?z and separator in [?\\, ?/],
       do: true

  defp normal_windows_discovery_root?(<<?\\, ?\\, _::binary>>), do: true
  defp normal_windows_discovery_root?(_path), do: false

  # `Path.expand/1` uses forward slashes for Windows drive paths. Preserve
  # backslashes for UNC paths because the Windows APIs treat their leading
  # double separator specially; ordinary drive paths remain in the canonical
  # form returned by `Path.expand/1`.
  defp normalize_windows_path(expanded, original) do
    if windows?() and is_binary(original) and String.starts_with?(original, "\\\\") do
      String.replace(expanded, "/", "\\")
    else
      expanded
    end
  end

  defp expand_metadata_path(path) do
    if windows?() do
      # Metadata paths have already passed the Windows absolute-path and
      # segment checks. Keep the same lexical representation as Path.expand/1;
      # only UNC paths need their leading backslashes preserved for Win32 APIs.
      path |> Path.expand() |> normalize_windows_path(path)
    else
      Path.expand(path)
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

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
          ensure_safe_metadata_target!(path)
          File.mkdir_p!(Path.dirname(path))
          ensure_safe_metadata_target!(path)
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
          ensure_safe_metadata_target!(entry.path)
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
    try do
      ensure_safe_metadata_target!(path)

      case File.rm(path) do
        :ok -> cleanup_metadata_recovery(entry.recovery, cleanup)
        {:error, :enoent} -> cleanup_metadata_recovery(entry.recovery, cleanup)
        {:error, reason} -> {:error, {path, reason}}
      end
    rescue
      error -> {:error, {path, {:unsafe_target, error}}}
    end
  end

  defp restore_metadata_target(
         %{
           path: path,
           original: {:regular, body},
           recovery: {:windows_backup, backup}
         } = entry,
         replace_fun,
         cleanup_fun
       ) do
    verification =
      case File.lstat(backup) do
        {:ok, %File.Stat{type: :regular, size: size}} when size == byte_size(body) ->
          case File.read(backup) do
            {:ok, ^body} -> :verified
            {:ok, _other_body} -> :mismatch
            {:error, reason} -> {:read_error, reason}
          end

        {:ok, %File.Stat{type: :regular, size: size}} ->
          {:size_mismatch, size}

        {:ok, %File.Stat{type: type}} ->
          {:invalid_type, type}

        {:error, reason} ->
          {:stat_error, reason}
      end

    case verification do
      :verified ->
        restore_from_known_backup(path, body, backup, replace_fun, cleanup_fun)

      _ ->
        Logger.warning(
          "Dala metadata recovery backup #{backup} does not match the original snapshot; " <>
            "restoring from the snapshot and leaving the backup for inspection " <>
            "(verification: #{inspect(verification)})"
        )

        restore_metadata_target(%{entry | recovery: :unknown}, replace_fun, cleanup_fun)
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
      ensure_safe_metadata_target!(path)
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

  defp restore_from_known_backup(path, body, backup, replace_fun, cleanup_fun) do
    fresh = metadata_temp_path(path, "rollback")

    try do
      # Stage the verified snapshot bytes instead of the backup path itself:
      # File.Replace can consume its source before reporting failure, while the
      # durable backup must remain available until the restore has committed.
      File.write!(fresh, body)
      ensure_safe_metadata_target!(path)
      recovery = replace_fun.(fresh, path, :rollback) |> normalize_recovery!()
      cleanup_metadata_recovery(recovery, cleanup_fun)
      cleanup_metadata_recovery({:windows_backup, backup}, cleanup_fun)
      File.rm(fresh)
      :ok
    rescue
      error ->
        retained = retained_snapshot_source(fresh, body)
        {:error, {path, {:known_backup_restore, backup, retained, error}}}
    end
  end

  defp retained_snapshot_source(path, body) do
    case File.read(path) do
      {:ok, ^body} ->
        path

      _ ->
        _ = File.rm(path)
        nil
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
        retained_snapshot_source(fresh, body)
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
    ensure_safe_metadata_target!(path)
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
