defmodule Dala.ReleaseTest do
  use ExUnit.Case, async: true

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
    assert Path.wildcard(root_metadata <> ".new-*") == []
    assert Path.wildcard(root_metadata <> ".rollback-*") == []
    assert Path.wildcard(discovery <> ".new-*") == []
  end
end
