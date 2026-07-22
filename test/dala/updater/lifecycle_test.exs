defmodule Dala.Updater.LifecycleTest do
  use ExUnit.Case, async: false

  alias Dala.Updater

  @attempt_id "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
  @other_attempt_id "6ba7b811-9dad-11d1-80b4-00c04fd430c8"

  setup do
    root =
      Path.join(System.tmp_dir!(), "dala-updater-lifecycle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "versions/v0.25.16"))
    File.write!(Path.join(root, "current.txt"), "v0.25.16\n")

    put_app_env(:release_root, root)
    put_app_env(:updater_platform, "windows-x86_64")
    put_app_env(:updater_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "a verified Windows archive is staged before the detached switch is scheduled", %{
    root: root
  } do
    {release, archive} = release_fixture("v99.0.0")
    stub_release_assets(archive)

    owner = self()

    put_app_env(:updater_restart, fn tag, previous_tag, expected_version ->
      send(owner, {:restart, tag, previous_tag, expected_version})
      :ok
    end)

    assert {:ok,
            %{
              attempt_id: attempt_id,
              status: "pending",
              updated_to: "v99.0.0"
            }} = Updater.apply_release(release)

    assert {:ok, ^attempt_id} = Ecto.UUID.cast(attempt_id)

    assert {:ok,
            %{
              attempt_id: ^attempt_id,
              status: "pending",
              target: "v99.0.0"
            }} = Updater.update_result(attempt_id)

    assert_receive {:restart, "v99.0.0", "v0.25.16", "99.0.0"}

    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
    assert File.regular?(Path.join(root, "versions/v99.0.0/bin/dala.bat"))
    assert File.regular?(Path.join(root, "versions/v99.0.0/run-dala.ps1"))

    assert File.regular?(
             Path.join(
               root,
               "versions/v99.0.0/lib/dala-99.0.0/priv/bin/dala_task_launcher.exe"
             )
           )

    assert File.regular?(
             Path.join(
               root,
               "versions/v99.0.0/lib/dala-99.0.0/priv/windows/update-dala.ps1"
             )
           )
  end

  test "the caller-provided attempt id is reserved before fetching and owns failures" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/mjason/dala/releases"
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert {:error, "GitHub responded with 503"} =
             Updater.apply_latest(@attempt_id, "v99.0.0")

    assert {:ok,
            %{
              attempt_id: @attempt_id,
              status: "failed",
              target: "v99.0.0",
              message: "GitHub responded with 503"
            }} = Updater.update_result(@attempt_id)

    assert {:ok, %{attempt_id: @other_attempt_id, status: "unknown"}} =
             Updater.update_result(@other_attempt_id)
  end

  test "apply rejects a changed latest tag before downloading any asset" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/repos/mjason/dala/releases" ->
          Req.Test.json(conn, [elem(release_fixture("v99.0.1"), 0)])

        path ->
          flunk("target mismatch must be rejected before fetching #{path}")
      end
    end)

    assert {:error,
            "latest server release changed from v99.0.0 to v99.0.1; check again before updating"} =
             Updater.apply_latest(@attempt_id, "v99.0.0")

    assert {:ok,
            %{
              attempt_id: @attempt_id,
              status: "failed",
              target: "v99.0.0"
            }} = Updater.update_result(@attempt_id)
  end

  test "two clients updating the same target keep independent attempt results" do
    {release, archive} = release_fixture("v99.0.0")
    hash = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/repos/mjason/dala/releases" -> Req.Test.json(conn, [release])
        "/archive" -> Plug.Conn.send_resp(conn, 200, archive)
        "/archive.sha256" -> Req.Test.text(conn, "#{hash}  dala.zip\n")
      end
    end)

    owner = self()

    put_app_env(:updater_restart, fn tag, _previous_tag, _expected_version ->
      send(owner, {:same_target_restart, self(), tag})

      receive do
        :finish_same_target_restart -> :ok
      end
    end)

    first = Task.async(fn -> Updater.apply_latest(@attempt_id, "v99.0.0") end)

    try do
      # Windows publish/unpack validation can take longer than ExUnit's
      # default 100ms receive window. Keep the lock-holder alive until the
      # restart callback is observed so a failed assertion cannot contaminate
      # the following lifecycle test with a stale global lock.
      assert_receive {:same_target_restart, first_pid, "v99.0.0"}, 5_000

      assert {:error, "another update is already in progress"} =
               Updater.apply_latest(@other_attempt_id, "v99.0.0")

      assert {:ok,
              %{
                attempt_id: @other_attempt_id,
                status: "failed",
                message: "another update is already in progress"
              }} = Updater.update_result(@other_attempt_id)

      assert {:ok, %{attempt_id: @attempt_id, status: "pending"}} =
               Updater.update_result(@attempt_id)

      send(first_pid, :finish_same_target_restart)

      assert {:ok, %{attempt_id: @attempt_id, updated_to: "v99.0.0"}} =
               Task.await(first, 5_000)

      assert {:ok, %{attempt_id: @attempt_id, status: "pending"}} =
               Updater.update_result(@attempt_id)
    after
      # If an assertion above fails before the callback is observed, release
      # the task's receive and wait for it to leave the global update lock.
      if Process.alive?(first.pid) do
        send(first.pid, :finish_same_target_restart)

        case Task.yield(first, 5_000) do
          nil -> _ = Task.shutdown(first, :brutal_kill)
          _result -> :ok
        end
      end
    end
  end

  test "attempt ids must be lowercase canonical UUIDs before any file is reserved", %{root: root} do
    uppercase = String.upcase(@attempt_id)

    Req.Test.stub(__MODULE__, fn _conn -> flunk("invalid attempts must not fetch releases") end)

    assert {:error, "invalid update attempt id"} =
             Updater.apply_latest(uppercase, "v99.0.0")

    refute File.exists?(Path.join([root, "logs", "update-results", "#{uppercase}.json"]))
  end

  test "a detached helper launch error is returned and leaves the old pointer authoritative", %{
    root: root
  } do
    {release, archive} = release_fixture("v99.0.1")
    stub_release_assets(archive)

    put_app_env(:updater_restart, fn _tag, _previous_tag, _expected_version ->
      {:error, "could not launch detached Windows update helper"}
    end)

    assert {:error, "could not launch detached Windows update helper"} =
             Updater.apply_release(release, @attempt_id)

    assert {:ok,
            %{
              status: "failed",
              target: "v99.0.1",
              message: "could not launch detached Windows update helper"
            }} = Updater.update_result(@attempt_id)

    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
    assert File.regular?(Path.join(root, "versions/v99.0.1/bin/dala.bat"))
  end

  test "a checksum failure neither installs nor schedules the release", %{root: root} do
    {release, archive} = release_fixture("v99.0.2")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/archive" -> Plug.Conn.send_resp(conn, 200, archive)
        "/archive.sha256" -> Req.Test.text(conn, String.duplicate("0", 64))
      end
    end)

    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "SHA-256 checksum mismatch for release archive"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.2"))
    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
  end

  test "an incomplete existing Windows target is downloaded and replaced", %{root: root} do
    target = Path.join(root, "versions/v99.0.4")
    File.mkdir_p!(Path.join(target, "bin"))
    File.mkdir_p!(Path.join(target, "lib/dala-99/priv/bin"))
    File.write!(Path.join(target, "bin/dala.bat"), "stale launcher\r\n")
    File.write!(Path.join(target, "run-dala.ps1"), "stale runner\r\n")

    File.write!(
      Path.join(target, "lib/dala-99/priv/bin/dala_task_launcher.exe"),
      "stale task launcher"
    )

    File.write!(Path.join(target, "stale-marker"), "partial install")

    {release, archive} = release_fixture("v99.0.4")
    owner = self()
    hash = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/archive" ->
          send(owner, :archive_downloaded)
          Plug.Conn.send_resp(conn, 200, archive)

        "/archive.sha256" ->
          Req.Test.text(conn, "#{hash}  dala.zip\n")
      end
    end)

    put_app_env(:updater_restart, fn tag, previous_tag, expected_version ->
      send(owner, {:restart, tag, previous_tag, expected_version})
      :ok
    end)

    assert {:ok, %{updated_to: "v99.0.4"}} = Updater.apply_release(release)
    assert_receive :archive_downloaded
    assert_receive {:restart, "v99.0.4", "v0.25.16", "99.0.4"}

    assert File.read!(Path.join(target, "bin/dala.bat")) == "@echo off\r\n"
    assert File.regular?(Path.join(target, "run-dala.ps1"))

    assert File.regular?(Path.join(target, "lib/dala-99.0.4/priv/bin/dala_task_launcher.exe"))

    assert File.regular?(Path.join(target, "lib/dala-99.0.4/priv/windows/update-dala.ps1"))

    refute File.exists?(Path.join(target, "stale-marker"))
  end

  test "a Windows archive without the task launcher is rejected", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.5",
        omit: ["lib/dala-99.0.5/priv/bin/dala_task_launcher.exe"]
      )

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive is missing Dala task launcher"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.5"))
    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
  end

  test "a Windows archive without the update helper is rejected", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.6",
        omit: ["lib/dala-99.0.6/priv/windows/update-dala.ps1"]
      )

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive is missing Windows update helper"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.6"))
    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
  end

  test "a Windows archive without the restart helper is rejected", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.13",
        omit: ["lib/dala-99.0.13/priv/windows/restart-dala.ps1"]
      )

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive is missing Windows restart helper"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.13"))
    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
  end

  test "a Windows archive without the Dala BEAM is rejected", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.14", omit: ["lib/dala-99.0.14/ebin/Elixir.Dala.beam"])

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive is missing Dala BEAM"} = Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.14"))
    assert File.read!(Path.join(root, "current.txt")) == "v0.25.16\n"
  end

  test "a Windows archive with a traversal entry is rejected before extraction", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.12", extra: [{"../escape", "must not be written"}])

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, message} = Updater.apply_release(release)
    assert message =~ "release archive contains unsafe entry"
    refute File.exists?(Path.join(root, "versions/v99.0.12"))
    refute File.exists?(Path.join(root, "versions/escape"))
  end

  test "misplaced Windows helper files do not satisfy the release layout", %{root: root} do
    {release, archive} =
      release_fixture("v99.0.8",
        omit: [
          "lib/dala-99.0.8/priv/bin/dala_task_launcher.exe",
          "lib/dala-99.0.8/priv/windows/update-dala.ps1"
        ],
        extra: [
          {"lib/other-1/priv/bin/dala_task_launcher.exe", "launcher"},
          {"nested/lib/dala-99.0.8/priv/windows/update-dala.ps1", "helper"}
        ]
      )

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive is missing Dala task launcher"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.8"))
  end

  test "a release whose embedded OTP version differs from its tag is rejected", %{root: root} do
    {release, archive} = release_fixture("v99.0.9", app_version: "99.0.8")
    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive start_erl.data does not match v99.0.9"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.9"))
  end

  test "placeholder OTP boot metadata is rejected", %{root: root} do
    {release, archive} = release_fixture("v99.0.10", start_boot: "not-an-erlang-boot-term")
    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive has an invalid releases/99.0.10/start.boot"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.10"))
  end

  test "a start.boot with the wrong top-level envelope is rejected", %{root: root} do
    {release, archive} =
      release_fixture(
        "v99.0.11",
        start_boot: :erlang.term_to_binary({:not_a_script, {:dala, "99.0.11"}, [:boot]})
      )

    stub_release_assets(archive)
    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release archive has an invalid releases/99.0.11/start.boot"} =
             Updater.apply_release(release)

    refute File.exists?(Path.join(root, "versions/v99.0.11"))
  end

  test "a complete target under a release root containing brackets is reused", %{root: root} do
    bracketed_root = Path.join(root, "Dala [preview]")
    target = Path.join(bracketed_root, "versions/v99.0.7")

    stage_windows_release(target, "99.0.7")
    File.write!(Path.join(bracketed_root, "current.txt"), "v0.25.16\n")

    put_app_env(:release_root, bracketed_root)

    Req.Test.stub(__MODULE__, fn _conn ->
      flunk("a complete existing target must not be downloaded again")
    end)

    owner = self()

    put_app_env(:updater_restart, fn tag, previous_tag, expected_version ->
      send(owner, {:restart, tag, previous_tag, expected_version})
      :ok
    end)

    assert {:ok, %{updated_to: "v99.0.7"}} =
             Updater.apply_release(elem(release_fixture("v99.0.7"), 0))

    assert_receive {:restart, "v99.0.7", "v0.25.16", "99.0.7"}
  end

  test "a concurrent update for one release root fails fast until activation finishes", %{
    root: root
  } do
    configure_unix_root(root)
    stage_unix_release(root, "v99.0.2")
    stage_unix_release(root, "v99.0.1")

    owner = self()

    put_app_env(:updater_restart, fn tag, _previous_tag, _expected_version ->
      send(owner, {:restart_started, self(), tag})

      if tag == "v99.0.2" do
        receive do
          :finish_restart -> :ok
        end
      else
        :ok
      end
    end)

    newer = Task.async(fn -> Updater.apply_release(unix_release("v99.0.2")) end)

    try do
      assert_receive {:restart_started, newer_pid, "v99.0.2"}, 5_000

      assert {:error, "another update is already in progress"} =
               Updater.apply_release(unix_release("v99.0.1"))

      refute_receive {:restart_started, _pid, "v99.0.1"}, 100

      send(newer_pid, :finish_restart)
      assert {:ok, %{updated_to: "v99.0.2"}} = Task.await(newer, 5_000)

      assert {:error, "release v99.0.1 is not newer than installed v99.0.2"} =
               Updater.apply_release(unix_release("v99.0.1"), @attempt_id)

      assert {:ok, current} = File.read_link(Path.join(root, "current"))
      assert Path.basename(current) == "v99.0.2"
    after
      if Process.alive?(newer.pid) do
        send(newer.pid, :finish_restart)

        case Task.yield(newer, 5_000) do
          nil -> _ = Task.shutdown(newer, :brutal_kill)
          _result -> :ok
        end
      end
    end
  end

  test "an activation exception rolls back, preserves its error and releases the lock", %{
    root: root
  } do
    configure_unix_root(root)
    stage_unix_release(root, "v99.0.1")
    stage_unix_release(root, "v99.0.2")

    put_app_env(:updater_restart, fn tag, _previous_tag, _expected_version ->
      case tag do
        "v99.0.1" -> raise "restart crashed"
        "v0.25.16" -> throw(:rollback_restart_crashed)
        _ -> :ok
      end
    end)

    assert {:error,
            "service restart raised: restart crashed; rollback restart failed: service restart threw: :rollback_restart_crashed"} =
             Updater.apply_release(unix_release("v99.0.1"), @attempt_id)

    assert {:ok,
            %{
              status: "failed",
              target: "v99.0.1",
              rolled_back: false,
              message:
                "service restart raised: restart crashed; rollback restart failed: service restart threw: :rollback_restart_crashed"
            }} = Updater.update_result(@attempt_id)

    assert {:ok, current} = File.read_link(Path.join(root, "current"))
    assert Path.basename(current) == "v0.25.16"

    assert {:ok, %{updated_to: "v99.0.2"}} =
             Updater.apply_release(unix_release("v99.0.2"))
  end

  test "restart throws and exits are normalized and rolled back", %{root: root} do
    configure_unix_root(root)
    stage_unix_release(root, "v99.0.3")
    stage_unix_release(root, "v99.0.4")

    put_app_env(:updater_restart, fn tag, _previous_tag, _expected_version ->
      case tag do
        "v99.0.3" -> throw(:restart_thrown)
        "v99.0.4" -> exit(:restart_exited)
        _ -> :ok
      end
    end)

    assert {:error, "service restart threw: :restart_thrown"} =
             Updater.apply_release(unix_release("v99.0.3"))

    assert {:ok, current} = File.read_link(Path.join(root, "current"))
    assert Path.basename(current) == "v0.25.16"

    assert {:error, "service restart exited: :restart_exited"} =
             Updater.apply_release(unix_release("v99.0.4"))

    assert {:ok, current} = File.read_link(Path.join(root, "current"))
    assert Path.basename(current) == "v0.25.16"
  end

  test "a target older than the installed pointer is rejected before download", %{root: root} do
    File.write!(Path.join(root, "current.txt"), "v99.1.0\n")

    Req.Test.stub(__MODULE__, fn _conn ->
      flunk("an older target must be rejected before downloading")
    end)

    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "release v99.0.9 is not newer than installed v99.1.0"} =
             Updater.apply_release(elem(release_fixture("v99.0.9"), 0))
  end

  test "activation does not overwrite a pointer changed during installation", %{root: root} do
    {release, archive} = release_fixture("v99.0.3")
    hash = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/archive" ->
          File.write!(Path.join(root, "current.txt"), "v99.0.1\n")
          Plug.Conn.send_resp(conn, 200, archive)

        "/archive.sha256" ->
          Req.Test.text(conn, "#{hash}  dala.zip\n")
      end
    end)

    put_app_env(:updater_restart, fn _, _, _ -> flunk("restart must not be scheduled") end)

    assert {:error, "current release changed from v0.25.16 to v99.0.1 during update"} =
             Updater.apply_release(release)

    assert File.read!(Path.join(root, "current.txt")) == "v99.0.1\n"
  end

  test "rollback does not overwrite a pointer changed by another updater", %{root: root} do
    configure_unix_root(root)
    stage_unix_release(root, "v99.0.3")
    File.mkdir_p!(Path.join(root, "versions/v99.0.2"))

    put_app_env(:updater_restart, fn tag, _previous_tag, _expected_version ->
      if tag == "v99.0.3" do
        replace_symlink(
          Path.join(root, "current"),
          Path.join(root, "versions/v99.0.2")
        )

        {:error, "service restart failed"}
      else
        flunk("the previous release must not restart after a skipped rollback")
      end
    end)

    assert {:error,
            "service restart failed; rollback skipped: current release changed from v99.0.3 to v99.0.2 during update"} =
             Updater.apply_release(unix_release("v99.0.3"))

    assert {:ok, current} = File.read_link(Path.join(root, "current"))
    assert Path.basename(current) == "v99.0.2"
  end

  defp release_fixture(tag, opts \\ []) do
    omitted = opts |> Keyword.get(:omit, []) |> MapSet.new()
    version = String.trim_leading(tag, "v")
    app_version = Keyword.get(opts, :app_version, version)
    erts_version = "16.1.2"

    start_boot =
      Keyword.get_lazy(opts, :start_boot, fn ->
        :erlang.term_to_binary({:script, {~c"dala", String.to_charlist(app_version)}, [:boot]})
      end)

    release_metadata =
      "{release,{\"dala\",\"#{app_version}\"},{erts,\"#{erts_version}\"}," <>
        "[{kernel,\"1\",permanent},{stdlib,\"1\",permanent},{dala,\"#{app_version}\",permanent}]}.\n"

    app_metadata =
      "{application,dala,[{vsn,\"#{app_version}\"}," <>
        "{modules,['Elixir.Dala.Application']},{applications,[kernel,stdlib]}," <>
        "{mod,{'Elixir.Dala.Application',[]}}]}.\n"

    entries =
      [
        {~c"bin/dala.bat", "@echo off\r\n"},
        {~c"run-dala.ps1", "$ErrorActionPreference = 'Stop'\r\n"},
        {String.to_charlist("releases/start_erl.data"), "#{erts_version} #{app_version}\n"},
        {String.to_charlist("releases/#{app_version}/start.boot"), start_boot},
        {String.to_charlist("releases/#{app_version}/dala.rel"), release_metadata},
        {String.to_charlist("erts-#{erts_version}/bin/erl.exe"), "erl"},
        {String.to_charlist("lib/dala-#{app_version}/ebin/dala.app"), app_metadata},
        {String.to_charlist("lib/dala-#{app_version}/ebin/Elixir.Dala.beam"), "beam"},
        {String.to_charlist("lib/dala-#{app_version}/priv/bin/dala_task_launcher.exe"),
         "launcher"},
        {String.to_charlist("lib/dala-#{app_version}/priv/windows/update-dala.ps1"),
         "update helper"},
        {String.to_charlist("lib/dala-#{app_version}/priv/windows/restart-dala.ps1"),
         "restart helper"},
        {String.to_charlist("lib/dala-#{app_version}/priv/windows/publish-dala.ps1"),
         "publish helper"}
      ]
      |> Kernel.++(
        Enum.map(Keyword.get(opts, :extra, []), fn {name, contents} ->
          {String.to_charlist(name), contents}
        end)
      )
      |> Enum.reject(fn {name, _contents} -> MapSet.member?(omitted, List.to_string(name)) end)

    {:ok, {_name, archive}} =
      :zip.create(
        ~c"dala.zip",
        entries,
        [:memory]
      )

    release = %{
      "tag_name" => tag,
      "assets" => [
        %{
          "name" => "dala-#{tag}-windows-x86_64.zip",
          "browser_download_url" => "https://updater.test/archive"
        },
        %{
          "name" => "dala-#{tag}-windows-x86_64.zip.sha256",
          "browser_download_url" => "https://updater.test/archive.sha256"
        }
      ]
    }

    {release, archive}
  end

  defp stub_release_assets(archive) do
    hash = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/archive" -> Plug.Conn.send_resp(conn, 200, archive)
        "/archive.sha256" -> Req.Test.text(conn, "#{hash}  dala.zip\n")
      end
    end)
  end

  defp unix_release(tag) do
    %{
      "tag_name" => tag,
      "assets" => [
        %{
          "name" => "dala-#{tag}-linux-x86_64.tar.gz",
          "browser_download_url" => "https://updater.test/archive"
        },
        %{
          "name" => "dala-#{tag}-linux-x86_64.tar.gz.sha256",
          "browser_download_url" => "https://updater.test/archive.sha256"
        }
      ]
    }
  end

  defp configure_unix_root(root) do
    put_app_env(:updater_platform, "linux-x86_64")
    replace_symlink(Path.join(root, "current"), Path.join(root, "versions/v0.25.16"))
  end

  defp stage_unix_release(root, tag) do
    version = String.trim_leading(tag, "v")
    release = Path.join([root, "versions", tag])
    stage_release_layout(release, version, "erl")
    File.write!(Path.join(release, "bin/dala"), "#!/bin/sh\n")
    helper = Path.join(release, "lib/dala-#{version}/priv/unix/update-dala.sh")
    File.mkdir_p!(Path.dirname(helper))
    File.write!(helper, "#!/bin/sh\n")
  end

  defp stage_windows_release(release, version) do
    stage_release_layout(release, version, "erl.exe")
    File.write!(Path.join(release, "bin/dala.bat"), "@echo off\r\n")
    File.write!(Path.join(release, "run-dala.ps1"), "runner\r\n")
    app = Path.join(release, "lib/dala-#{version}")
    File.mkdir_p!(Path.join(app, "priv/bin"))
    File.mkdir_p!(Path.join(app, "priv/windows"))
    File.write!(Path.join(app, "priv/bin/dala_task_launcher.exe"), "launcher")
    File.write!(Path.join(app, "priv/windows/update-dala.ps1"), "helper")
    File.write!(Path.join(app, "priv/windows/restart-dala.ps1"), "restart")
    File.write!(Path.join(app, "priv/windows/publish-dala.ps1"), "publisher")
  end

  defp stage_release_layout(release, version, erl_name) do
    erts_version = "16.1.2"
    File.mkdir_p!(Path.join(release, "bin"))
    File.mkdir_p!(Path.join(release, "releases/#{version}"))
    File.mkdir_p!(Path.join(release, "erts-#{erts_version}/bin"))
    File.mkdir_p!(Path.join(release, "lib/dala-#{version}/ebin"))
    File.write!(Path.join(release, "releases/start_erl.data"), "#{erts_version} #{version}\n")

    File.write!(
      Path.join(release, "releases/#{version}/start.boot"),
      :erlang.term_to_binary({:script, {~c"dala", String.to_charlist(version)}, [:boot]})
    )

    File.write!(
      Path.join(release, "releases/#{version}/dala.rel"),
      "{release,{\"dala\",\"#{version}\"},{erts,\"#{erts_version}\"}," <>
        "[{kernel,\"1\",permanent},{stdlib,\"1\",permanent},{dala,\"#{version}\",permanent}]}.\n"
    )

    File.write!(Path.join(release, "erts-#{erts_version}/bin/#{erl_name}"), "erl")

    File.write!(
      Path.join(release, "lib/dala-#{version}/ebin/dala.app"),
      "{application,dala,[{vsn,\"#{version}\"}," <>
        "{modules,['Elixir.Dala.Application']},{applications,[kernel,stdlib]}," <>
        "{mod,{'Elixir.Dala.Application',[]}}]}.\n"
    )

    File.write!(Path.join(release, "lib/dala-#{version}/ebin/Elixir.Dala.beam"), "beam")
  end

  defp replace_symlink(link, target) do
    case File.rm(link) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> File.rmdir!(link)
    end

    File.ln_s!(target, link)
  end

  defp put_app_env(key, value) do
    previous = Application.get_env(:dala, key, :unset)
    Application.put_env(:dala, key, value)

    on_exit(fn ->
      case previous do
        :unset -> Application.delete_env(:dala, key)
        value -> Application.put_env(:dala, key, value)
      end
    end)
  end
end
