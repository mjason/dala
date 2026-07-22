defmodule Dala.ReleaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # `Path.wildcard/1` has different absolute-drive handling on Windows. The
  # release code only creates these artifacts beside the destination, so list
  # that directory and compare names instead of relying on wildcard parsing.
  defp metadata_temporaries(path, suffix) do
    prefix = String.downcase(Path.basename(path) <> suffix)

    case File.ls(Path.dirname(path)) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(String.downcase(&1), prefix))
        |> Enum.map(&Path.join(Path.dirname(path), &1))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        flunk("could not list metadata temporary directory: #{inspect(reason)}")
    end
  end

  test "sync_install_metadata makes root and discovery reflect the runtime config" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-metadata-#{System.unique_integer([:positive])}")

    root = Path.join(base, "Dala [preview]")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join([base, "roaming", "Dala", "install.json"])
    config_file = Path.join([base, "shared config", "dala.jsonc"])
    data_dir = Path.join(base, "data")

    File.mkdir_p!(root)

    File.write!(
      root_metadata,
      Jason.encode!(%{
        "schemaVersion" => 1,
        "root" => root,
        "dataDir" => "stale-data",
        "configFile" => "stale-config",
        "taskName" => "StaleTask",
        "port" => 4400,
        "repo" => "stale/repo",
        "platform" => "windows-x86_64"
      })
    )

    on_exit(fn -> File.rm_rf(base) end)

    assert :ok =
             Dala.Release.sync_install_metadata(root_metadata, discovery, %{
               root: root,
               data_dir: data_dir,
               config_file: config_file,
               task_name: "DalaCustom",
               port: 4555,
               repo: "mjason/dala"
             })

    root_value = root_metadata |> File.read!() |> Jason.decode!()
    discovery_value = discovery |> File.read!() |> Jason.decode!()

    assert root_value == discovery_value
    assert root_value["root"] == root
    assert root_value["dataDir"] == data_dir
    assert root_value["configFile"] == config_file
    assert root_value["taskName"] == "DalaCustom"
    assert root_value["port"] == 4555
    assert root_value["repo"] == "mjason/dala"
    assert root_value["discoveryFile"] == Path.expand(discovery)
  end

  test "resolve_discovery_file prefers persisted metadata over bootstrap environment" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-discovery-path-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    persisted = Path.join(base, "persisted", "install.json")
    ambient = Path.join(base, "ambient", "install.json")
    on_exit(fn -> File.rm_rf(base) end)

    assert Dala.Release.resolve_discovery_file(
             %{"root" => root, "discoveryFile" => persisted},
             root_metadata_path: root_metadata,
             env: %{"DALA_DISCOVERY_FILE" => ambient, "APPDATA" => Path.join(base, "appdata")}
           ) == Path.expand(persisted)

    assert Dala.Release.resolve_discovery_file(
             %{"root" => root},
             root_metadata_path: root_metadata,
             env: %{"DALA_DISCOVERY_FILE" => ambient, "APPDATA" => Path.join(base, "appdata")}
           ) == Path.expand(ambient)

    assert Dala.Release.resolve_discovery_file(
             %{"root" => root},
             root_metadata_path: root_metadata,
             env: %{"APPDATA" => Path.join(base, "appdata")}
           ) == Path.expand(Path.join([base, "appdata", "Dala", "install.json"]))
  end

  test "resolve_discovery_file rejects relative and root metadata paths" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-invalid-discovery-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    on_exit(fn -> File.rm_rf(base) end)

    assert_raise RuntimeError, ~r/absolute path/, fn ->
      Dala.Release.resolve_discovery_file(
        %{"root" => root, "discoveryFile" => "relative/install.json"},
        root_metadata_path: root_metadata
      )
    end

    assert Dala.Release.resolve_discovery_file(
             %{"root" => root, "discoveryFile" => root_metadata},
             root_metadata_path: root_metadata
           ) == Path.expand(root_metadata)
  end

  test "sync_install_metadata rejects metadata for another root without touching discovery" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-mismatch-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)
    File.write!(root_metadata, Jason.encode!(%{"root" => Path.join(base, "other")}))
    File.write!(discovery, "keep\n")
    on_exit(fn -> File.rm_rf(base) end)

    assert_raise RuntimeError, ~r/root does not match/, fn ->
      Dala.Release.sync_install_metadata(root_metadata, discovery, %{
        root: root,
        data_dir: Path.join(base, "data"),
        config_file: Path.join(base, "config.jsonc"),
        task_name: "Dala",
        port: 4400,
        repo: "mjason/dala"
      })
    end

    assert File.read!(discovery) == "keep\n"
  end

  test "sync_install_metadata defaults a missing Windows service name to Dala" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-default-service-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)
    File.write!(root_metadata, Jason.encode!(%{"root" => root}))
    on_exit(fn -> File.rm_rf(base) end)

    assert :ok =
             Dala.Release.sync_install_metadata(root_metadata, discovery, %{
               root: root,
               data_dir: Path.join(base, "data"),
               config_file: Path.join(base, "config.jsonc"),
               port: 4400,
               repo: "mjason/dala"
             })

    assert root_metadata |> File.read!() |> Jason.decode!() |> Map.fetch!("taskName") == "Dala"
    assert discovery |> File.read!() |> Jason.decode!() |> Map.fetch!("taskName") == "Dala"
  end

  test "sync_install_metadata fails closed when root and discovery field presence diverges" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-discovery-presence-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)
    File.write!(root_metadata, Jason.encode!(%{"root" => root, "discoveryFile" => discovery}))
    original_discovery = Jason.encode!(%{"root" => root})
    File.write!(discovery, original_discovery)
    on_exit(fn -> File.rm_rf(base) end)

    assert_raise RuntimeError, ~r/disagree on discoveryFile/, fn ->
      Dala.Release.sync_install_metadata(root_metadata, discovery, %{
        root: root,
        data_dir: Path.join(base, "data"),
        config_file: Path.join(base, "config.jsonc"),
        task_name: "Dala",
        port: 4400,
        repo: "mjason/dala"
      })
    end

    assert File.read!(discovery) == original_discovery
  end

  test "sync_install_metadata permits a root metadata file as the discovery destination" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-discovery-same-path-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    File.mkdir_p!(root)
    File.write!(root_metadata, Jason.encode!(%{"root" => root, "discoveryFile" => root_metadata}))
    on_exit(fn -> File.rm_rf(base) end)

    assert :ok =
             Dala.Release.sync_install_metadata(root_metadata, root_metadata, %{
               root: root,
               data_dir: Path.join(base, "data"),
               config_file: Path.join(base, "config.jsonc"),
               task_name: "Dala",
               port: 4400,
               repo: "mjason/dala"
             })

    assert root_metadata |> File.read!() |> Jason.decode!() |> Map.fetch!("discoveryFile") ==
             Path.expand(root_metadata)
  end

  test "resolve_discovery_file rejects a symlinked ancestor" do
    if match?({:win32, _}, :os.type()) do
      :ok
    else
      base =
        Path.join(System.tmp_dir!(), "dala-release-discovery-symlink-#{System.unique_integer([:positive])}")

      real = Path.join(base, "real")
      link = Path.join(base, "link")
      root = Path.join(base, "root")
      File.mkdir_p!(real)
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(base) end)

      case File.ln_s(real, link) do
        :ok ->
          assert_raise RuntimeError, ~r/symbolic-link ancestor/, fn ->
            Dala.Release.resolve_discovery_file(
              %{"root" => root, "discoveryFile" => Path.join(link, "install.json")},
              root_metadata_path: Path.join(root, "install.json")
            )
          end

        {:error, _reason} ->
          :ok
      end
    end
  end

  test "committed Windows metadata replacement survives backup cleanup failure" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-backup-cleanup-#{System.unique_integer([:positive])}"
      )

    backup = Path.join(base, "install.json.backup-test")
    File.mkdir_p!(backup)
    File.write!(Path.join(backup, "original.json"), "old metadata")
    on_exit(fn -> File.rm_rf(base) end)

    log =
      capture_log(fn ->
        assert :ok = Dala.Release.cleanup_windows_backup(backup)
      end)

    assert log =~ "could not remove temporary Dala metadata backup"
    assert log =~ "leaving it for recovery"
    assert File.read!(Path.join(backup, "original.json")) == "old metadata"
  end

  test "metadata pair consumes a known first backup when the second replacement fails" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-pair-recovery-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    root_original = Jason.encode!(%{"root" => root, "copy" => "root-original"})
    discovery_original = Jason.encode!(%{"root" => root, "copy" => "discovery-original"})
    File.mkdir_p!(root)
    File.write!(root_metadata, root_original)
    File.write!(discovery, discovery_original)
    on_exit(fn -> File.rm_rf(base) end)

    events = :ets.new(:release_pair_recovery, [:ordered_set, :private])
    sequence = :atomics.new(1, [])

    record = fn event ->
      index = :atomics.add_get(sequence, 1, 1)
      true = :ets.insert(events, {index, event})
    end

    replace = fn source, destination, phase ->
      record.({phase, source, destination})

      if phase == :rollback and destination == root_metadata do
        record.({
          :known_backup_copy,
          source,
          File.exists?(root_metadata <> ".backup-injected"),
          File.read!(source)
        })
      end

      cond do
        phase == :commit and destination == root_metadata ->
          backup = root_metadata <> ".backup-injected"
          File.cp!(destination, backup)
          File.rm!(destination)
          File.rename!(source, destination)
          {:windows_backup, backup}

        phase == :commit and destination == discovery ->
          raise "injected second metadata replacement failure"

        phase == :rollback ->
          File.rm(destination)
          File.rename!(source, destination)
          :none
      end
    end

    cleanup = fn backup ->
      record.({:cleanup, backup})
      File.rm(backup)
    end

    assert_raise RuntimeError, "injected second metadata replacement failure", fn ->
      Dala.Release.sync_install_metadata(
        root_metadata,
        discovery,
        %{
          root: root,
          data_dir: Path.join(base, "data"),
          config_file: Path.join(base, "config.jsonc"),
          task_name: "Dala",
          port: 4400,
          repo: "mjason/dala"
        },
        replace_fun: replace,
        cleanup_fun: cleanup
      )
    end

    assert File.read!(root_metadata) == root_original
    assert File.read!(discovery) == discovery_original
    refute File.exists?(root_metadata <> ".backup-injected")

    recorded = events |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

    assert Enum.any?(recorded, fn
             {:known_backup_copy, source, true, ^root_original} ->
               String.starts_with?(source, root_metadata <> ".rollback-")

             _ ->
               false
           end)

    assert metadata_temporaries(root_metadata, ".new-") == []
    assert metadata_temporaries(root_metadata, ".rollback-") == []
    assert metadata_temporaries(discovery, ".new-") == []
    assert metadata_temporaries(discovery, ".rollback-") == []
  end

  test "ambiguous rollback keeps the original known backup when its copy is consumed" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-rollback-source-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    backup = root_metadata <> ".backup-injected"
    root_original = Jason.encode!(%{"root" => root, "copy" => "durable-old-bytes"})
    File.mkdir_p!(root)
    File.write!(root_metadata, root_original)
    File.write!(discovery, Jason.encode!(%{"root" => root, "copy" => "old discovery"}))
    on_exit(fn -> File.rm_rf(base) end)

    replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_metadata ->
          File.cp!(destination, backup)
          File.rm!(destination)
          File.rename!(source, destination)
          {:windows_backup, backup}

        phase == :commit and destination == discovery ->
          raise "injected second metadata replacement failure"

        phase == :rollback and destination == discovery ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none

        phase == :rollback and destination == root_metadata ->
          refute source == backup
          assert File.read!(source) == root_original
          File.rm!(source)
          raise "injected rollback failure after consuming source"
      end
    end

    error =
      assert_raise RuntimeError, fn ->
        Dala.Release.sync_install_metadata(
          root_metadata,
          discovery,
          %{
            root: root,
            data_dir: Path.join(base, "data"),
            config_file: Path.join(base, "config.jsonc"),
            task_name: "Dala",
            port: 4400,
            repo: "mjason/dala"
          },
          replace_fun: replace,
          cleanup_fun: &File.rm/1
        )
      end

    assert Exception.message(error) =~ "rollback failed"
    assert Exception.message(error) =~ backup
    assert File.read!(backup) == root_original
  end

  test "successful snapshot rollback cleans an ambiguous Windows backup" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-ambiguous-backup-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    backup = root_metadata <> ".backup-injected"
    root_original = Jason.encode!(%{"root" => root, "copy" => "root-original"})
    File.mkdir_p!(root)
    File.write!(root_metadata, root_original)
    File.write!(discovery, Jason.encode!(%{"root" => root, "copy" => "discovery-original"}))
    on_exit(fn -> File.rm_rf(base) end)

    replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_metadata ->
          File.cp!(destination, backup)
          File.rm!(destination)
          File.rename!(source, destination)

          raise Dala.Release.MetadataReplacementError,
            message: "injected ambiguous committed replacement",
            recovery: {:ambiguous_windows_backup, backup}

        phase == :rollback and destination == root_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none
      end
    end

    assert_raise Dala.Release.MetadataReplacementError,
                 "injected ambiguous committed replacement",
                 fn ->
                   Dala.Release.sync_install_metadata(
                     root_metadata,
                     discovery,
                     %{
                       root: root,
                       data_dir: Path.join(base, "data"),
                       config_file: Path.join(base, "config.jsonc"),
                       task_name: "Dala",
                       port: 4400,
                       repo: "mjason/dala"
                     },
                     replace_fun: replace,
                     cleanup_fun: &File.rm/1
                   )
                 end

    assert File.read!(root_metadata) == root_original
    refute File.exists?(backup)
  end

  test "failed Windows replacement reports its generated recovery backup" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-failed-replacement-backup-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    discovery_backup = discovery <> ".backup-injected"
    root_original = Jason.encode!(%{"root" => root, "copy" => "root-original"})
    discovery_original = Jason.encode!(%{"root" => root, "copy" => "discovery-original"})
    File.mkdir_p!(root)
    File.write!(root_metadata, root_original)
    File.write!(discovery, discovery_original)
    on_exit(fn -> File.rm_rf(base) end)

    replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none

        phase == :commit and destination == discovery ->
          File.cp!(destination, discovery_backup)
          File.rm!(destination)
          File.rename!(source, destination)

          raise Dala.Release.MetadataReplacementError,
            message: "injected failed replacement with a durable backup",
            recovery: {:windows_backup, discovery_backup}

        phase == :rollback and destination == discovery ->
          File.rm!(source)
          raise "injected discovery rollback failure"

        phase == :rollback and destination == root_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none
      end
    end

    error =
      assert_raise RuntimeError, fn ->
        Dala.Release.sync_install_metadata(
          root_metadata,
          discovery,
          %{
            root: root,
            data_dir: Path.join(base, "data"),
            config_file: Path.join(base, "config.jsonc"),
            task_name: "Dala",
            port: 4400,
            repo: "mjason/dala"
          },
          replace_fun: replace,
          cleanup_fun: &File.rm/1
        )
      end

    assert Exception.message(error) =~ "known recovery backups: #{discovery_backup}"
    assert File.read!(discovery_backup) == discovery_original
    assert File.read!(root_metadata) == root_original
  end

  test "metadata pair defers backup cleanup until every replacement commits" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-pair-cleanup-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)
    File.write!(root_metadata, Jason.encode!(%{"root" => root}))
    File.write!(discovery, Jason.encode!(%{"root" => root, "copy" => "old discovery"}))
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, events} = Agent.start_link(fn -> [] end)

    replace = fn source, destination, phase ->
      Agent.update(events, &[{:replace, phase, destination} | &1])
      backup = destination <> ".backup-injected"
      File.cp!(destination, backup)
      File.rm!(destination)
      File.rename!(source, destination)
      {:windows_backup, backup}
    end

    cleanup = fn backup ->
      Agent.update(events, &[{:cleanup, backup} | &1])
      {:error, :eacces}
    end

    log =
      capture_log(fn ->
        assert :ok =
                 Dala.Release.sync_install_metadata(
                   root_metadata,
                   discovery,
                   %{
                     root: root,
                     data_dir: Path.join(base, "data"),
                     config_file: Path.join(base, "config.jsonc"),
                     task_name: "Dala",
                     port: 4555,
                     repo: "mjason/dala"
                   },
                   replace_fun: replace,
                   cleanup_fun: cleanup
                 )
      end)

    recorded = events |> Agent.get(&Enum.reverse/1)
    Agent.stop(events)

    assert Enum.map(recorded, fn
             {:replace, phase, _path} -> phase
             {:cleanup, _path} -> :cleanup
           end) == [:commit, :commit, :cleanup, :cleanup]

    assert log =~ "leaving it for recovery"
    assert File.exists?(root_metadata <> ".backup-injected")
    assert File.exists?(discovery <> ".backup-injected")
    assert root_metadata |> File.read!() |> Jason.decode!() |> Map.fetch!("port") == 4555
    assert discovery |> File.read!() |> Jason.decode!() |> Map.fetch!("port") == 4555
  end

  test "metadata pair serializes case-equivalent Windows paths through rollback" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-pair-lock-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "MetadataRoot")
    # Windows resolves these spellings to the same directory. On a
    # case-sensitive test host, use the canonical spelling so this regression
    # test does not require symlink privileges; the shared-path lock test below
    # still exercises alias-free concurrency on every platform.
    root_alias =
      if match?({:win32, _}, :os.type()), do: Path.join(base, "metadataroot"), else: root

    root_metadata = Path.join(root, "install.json")
    root_metadata_alias = Path.join(root_alias, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)

    original = Jason.encode!(%{"root" => root, "port" => 4300})
    File.write!(root_metadata, original)
    File.write!(discovery, original)
    on_exit(fn -> File.rm_rf(base) end)

    parent = self()
    release_first = make_ref()

    first_replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          send(parent, {:first_root_committed, self()})

          receive do
            {^release_first, :fail_discovery} -> :none
          end

        phase == :commit and destination == discovery ->
          raise "injected first discovery replacement failure"

        phase == :rollback ->
          File.rm(destination)
          File.rename!(source, destination)
          :none
      end
    end

    second_replace = fn source, destination, :commit ->
      send(parent, {:second_replace_started, destination})
      File.rm(destination)
      File.rename!(source, destination)
      :none
    end

    first =
      Task.async(fn ->
        try do
          Dala.Release.sync_install_metadata(
            root_metadata,
            discovery,
            %{
              root: root,
              data_dir: Path.join(base, "first-data"),
              config_file: Path.join(base, "first.jsonc"),
              task_name: "Dala",
              port: 4501,
              repo: "mjason/dala"
            },
            replace_fun: first_replace
          )
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    assert_receive {:first_root_committed, first_pid}, 1_000
    assert first_pid == first.pid

    second =
      Task.async(fn ->
        send(parent, {:second_calling, self()})

        Dala.Release.sync_install_metadata(
          root_metadata_alias,
          discovery,
          %{
            root: root_alias,
            data_dir: Path.join(base, "second-data"),
            config_file: Path.join(base, "second.jsonc"),
            task_name: "Dala",
            port: 4502,
            repo: "mjason/dala"
          },
          replace_fun: second_replace
        )
      end)

    assert_receive {:second_calling, second_pid}, 1_000
    assert second_pid == second.pid

    interleaved =
      receive do
        {:second_replace_started, _destination} -> true
      after
        250 -> false
      end

    send(first.pid, {release_first, :fail_discovery})

    assert Task.await(first, 5_000) ==
             {:error, "injected first discovery replacement failure"}

    assert Task.await(second, 5_000) == :ok
    refute interleaved

    root_value = root_metadata |> File.read!() |> Jason.decode!()
    discovery_value = discovery |> File.read!() |> Jason.decode!()
    assert root_value == discovery_value
    assert root_value["port"] == 4502
    assert root_value["root"] == root_alias
  end

  test "metadata pair serializes transactions that share one discovery path" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-shared-discovery-lock-#{System.unique_integer([:positive])}"
      )

    root_one = Path.join(base, "root-one")
    root_two = Path.join(base, "root-two")
    root_one_metadata = Path.join(root_one, "install.json")
    root_two_metadata = Path.join(root_two, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root_one)
    File.mkdir_p!(root_two)

    original_one = Jason.encode!(%{"root" => root_one, "port" => 4300})
    original_two = Jason.encode!(%{"root" => root_two, "port" => 4300})
    File.write!(root_one_metadata, original_one)
    File.write!(root_two_metadata, original_two)
    File.write!(discovery, original_one)
    on_exit(fn -> File.rm_rf(base) end)

    parent = self()
    release_first = make_ref()
    start_second = make_ref()

    first_replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_one_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          send(parent, {:shared_first_root_committed, self()})

          receive do
            {^release_first, :continue} -> :none
          end

        phase == :commit and destination == discovery ->
          raise "injected shared discovery replacement failure"

        phase == :rollback ->
          File.rm(destination)
          File.rename!(source, destination)
          :none
      end
    end

    second_replace = fn source, destination, phase ->
      if phase == :commit do
        send(parent, {:shared_second_replace_started, destination})
      end

      File.rm(destination)
      File.rename!(source, destination)
      :none
    end

    first =
      Task.async(fn ->
        try do
          Dala.Release.sync_install_metadata(
            root_one_metadata,
            discovery,
            %{
              root: root_one,
              data_dir: Path.join(base, "first-data"),
              config_file: Path.join(base, "first.jsonc"),
              task_name: "Dala",
              port: 4501,
              repo: "mjason/dala"
            },
            replace_fun: first_replace
          )
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    assert_receive {:shared_first_root_committed, first_pid}, 1_000
    assert first_pid == first.pid

    second =
      Task.async(fn ->
        send(parent, {:shared_second_calling, self()})

        receive do
          {^start_second, :go} -> :ok
        end

        Dala.Release.sync_install_metadata(
          root_two_metadata,
          discovery,
          %{
            root: root_two,
            data_dir: Path.join(base, "second-data"),
            config_file: Path.join(base, "second.jsonc"),
            task_name: "Dala",
            port: 4502,
            repo: "mjason/dala"
          },
          replace_fun: second_replace
        )
      end)

    assert_receive {:shared_second_calling, second_pid}, 1_000
    assert second_pid == second.pid
    send(second.pid, {start_second, :go})
    refute_receive {:shared_second_replace_started, _destination}, 500

    send(first.pid, {release_first, :continue})

    assert Task.await(first, 5_000) ==
             {:error, "injected shared discovery replacement failure"}

    assert_receive {:shared_second_replace_started, ^root_two_metadata}, 5_000
    assert_receive {:shared_second_replace_started, ^discovery}, 5_000
    assert Task.await(second, 5_000) == :ok

    root_value = root_two_metadata |> File.read!() |> Jason.decode!()
    discovery_value = discovery |> File.read!() |> Jason.decode!()
    assert root_value == discovery_value
    assert root_value["root"] == root_two
    assert root_value["port"] == 4502
  end

  test "metadata pair deduplicates case-equivalent destination paths on Windows" do
    unless match?({:win32, _}, :os.type()) do
      :ok
    else
      base =
        Path.join(
          System.tmp_dir!(),
          "dala-release-case-dedup-#{System.unique_integer([:positive])}"
        )

      root = Path.join(base, "MetadataRoot")
      root_alias = Path.join(base, "metadataroot")
      root_metadata = Path.join(root, "install.json")
      root_metadata_alias = Path.join(root_alias, "INSTALL.JSON")
      original = Jason.encode!(%{"root" => root, "port" => 4300})
      File.mkdir_p!(root)
      File.write!(root_metadata, original)
      on_exit(fn -> File.rm_rf(base) end)

      {:ok, calls} = Agent.start_link(fn -> [] end)

      replace = fn source, destination, phase ->
        Agent.update(calls, &[{phase, destination} | &1])
        File.rm!(destination)
        File.rename!(source, destination)
        :none
      end

      assert :ok =
               Dala.Release.sync_install_metadata(
                 root_metadata,
                 root_metadata_alias,
                 %{
                   root: root,
                   data_dir: Path.join(base, "data"),
                   config_file: Path.join(base, "config.jsonc"),
                   task_name: "Dala",
                   port: 4400,
                   repo: "mjason/dala"
                 },
                 replace_fun: replace
               )

      recorded = calls |> Agent.get(&Enum.reverse/1)
      Agent.stop(calls)

      assert Enum.count(recorded, fn {phase, _path} -> phase == :commit end) == 1
      assert root_metadata |> File.read!() |> Jason.decode!() |> Map.fetch!("port") == 4400
    end
  end

  test "sync_install_metadata restores the first file when the second replacement fails" do
    base =
      Path.join(System.tmp_dir!(), "dala-release-rollback-#{System.unique_integer([:positive])}")

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    File.mkdir_p!(root)
    File.mkdir_p!(discovery)

    original = Jason.encode!(%{"root" => root, "unchanged" => true})
    File.write!(root_metadata, original)
    on_exit(fn -> File.rm_rf(base) end)

    result =
      try do
        Dala.Release.sync_install_metadata(root_metadata, discovery, %{
          root: root,
          data_dir: Path.join(base, "data"),
          config_file: Path.join(base, "config.jsonc"),
          task_name: "Dala",
          port: 4400,
          repo: "mjason/dala"
        })
      rescue
        error -> {:error, error}
      end

    assert {:error, _error} = result
    assert File.read!(root_metadata) == original
    assert File.dir?(discovery)
    assert metadata_temporaries(root_metadata, ".new-") == []
    assert metadata_temporaries(root_metadata, ".backup-") == []
    assert metadata_temporaries(root_metadata, ".rollback-") == []
    assert metadata_temporaries(discovery, ".new-") == []
    assert metadata_temporaries(discovery, ".backup-") == []
  end

  test "snapshot rollback retains old bytes when a post-commit restore consumes its source" do
    base =
      Path.join(
        System.tmp_dir!(),
        "dala-release-snapshot-recovery-#{System.unique_integer([:positive])}"
      )

    root = Path.join(base, "root")
    root_metadata = Path.join(root, "install.json")
    discovery = Path.join(base, "discovery.json")
    original = Jason.encode!(%{"root" => root, "old" => true})
    File.mkdir_p!(root)
    File.write!(root_metadata, original)
    File.write!(discovery, original)
    on_exit(fn -> File.rm_rf(base) end)

    replace = fn source, destination, phase ->
      cond do
        phase == :commit and destination == root_metadata ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none

        phase == :commit and destination == discovery ->
          raise "injected second metadata replacement failure"

        phase == :rollback and destination == discovery ->
          File.rm!(destination)
          File.rename!(source, destination)
          :none

        phase == :rollback and destination == root_metadata ->
          File.rm!(source)
          raise "injected snapshot rollback failure after consuming source"
      end
    end

    error =
      assert_raise RuntimeError, fn ->
        Dala.Release.sync_install_metadata(
          root_metadata,
          discovery,
          %{
            root: root,
            data_dir: Path.join(base, "data"),
            config_file: Path.join(base, "config.jsonc"),
            task_name: "Dala",
            port: 4400,
            repo: "mjason/dala"
          },
          replace_fun: replace
        )
      end

    assert Exception.message(error) =~ "rollback failed"
    retained = metadata_temporaries(root_metadata, ".rollback-recovery-")
    assert length(retained) == 1
    assert File.read!(hd(retained)) == original
  end
end
