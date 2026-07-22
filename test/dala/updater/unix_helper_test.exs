defmodule Dala.Updater.UnixHelperTest do
  use ExUnit.Case, async: true

  @moduletag skip: Dala.TestPlatform.windows?()

  @attempt_id "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  setup do
    root = Path.join(System.tmp_dir!(), "dala-unix-helper-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "test-bin")
    File.mkdir_p!(Path.join(root, "versions/v0.25.17"))
    File.mkdir_p!(Path.join(root, "versions/v99.0.0"))
    File.mkdir_p!(bin)
    File.ln_s!(Path.join(root, "versions/v0.25.17"), Path.join(root, "current"))

    write_executable(Path.join(bin, "systemctl"), """
    #!/bin/sh
    printf '%s\n' "$*" >> "$DALA_TEST_EVENTS"
    exit 0
    """)

    write_executable(Path.join(bin, "curl"), """
    #!/bin/sh
    tag=$(basename "$(readlink "$DALA_TEST_ROOT/current")")
    case "$DALA_TEST_MODE:$tag" in
      success:v99.0.0) printf '99.0.0' ;;
      mismatch:v99.0.0) printf '98.0.0' ;;
      rollback:v99.0.0|rollback_broken:v99.0.0) exit 7 ;;
      rollback_hold:v99.0.0) exit 7 ;;
      hold:v99.0.0)
        while [ ! -f "$DALA_TEST_RELEASE" ]; do sleep 0.01; done
        printf '99.0.0'
        ;;
      mismatch:v0.25.17|rollback:v0.25.17) printf '0.25.17' ;;
      rollback_broken:v0.25.17) exit 7 ;;
      rollback_hold:v0.25.17)
        : > "$DALA_TEST_ROLLBACK_WAITING"
        while [ ! -f "$DALA_TEST_RELEASE" ]; do sleep 0.01; done
        printf '0.25.17'
        ;;
      *) exit 8 ;;
    esac
    """)

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, bin: bin}
  end

  test "restart acceptance stays pending until the target version is actually healthy", context do
    {status, result} = run_helper(context, "success")

    assert status == 0
    assert result["attempt_id"] == @attempt_id
    assert result["success"] == true
    assert result["rolled_back"] == false
    assert result["target"] == "v99.0.0"
    assert current_tag(context.root) == "v99.0.0"
  end

  test "a target that never becomes healthy is rolled back and reported as failed", context do
    {status, result} = run_helper(context, "rollback")

    assert status != 0
    assert result["success"] == false
    assert result["rolled_back"] == true
    assert result["message"] =~ "did not become healthy"
    assert current_tag(context.root) == "v0.25.17"
    assert File.read!(Path.join(context.root, "events")) =~ "restart --no-block dala"
  end

  test "a version mismatch is a failed activation even when HTTP responds", context do
    {status, result} = run_helper(context, "mismatch")

    assert status != 0
    assert result["success"] == false
    assert result["rolled_back"] == true
    assert result["message"] =~ "did not become healthy"
    assert current_tag(context.root) == "v0.25.17"
  end

  test "rollback is not reported as complete when the previous service stays unhealthy",
       context do
    {status, result} = run_helper(context, "rollback_broken")

    assert status != 0
    assert result["success"] == false
    assert result["rolled_back"] == false
    assert result["message"] =~ "rollback did not restore"
    assert current_tag(context.root) == "v0.25.17"
  end

  test "the activation lock spans detached health checks", context do
    first_result = Path.join(context.root, "first-result.json")
    second_result = Path.join(context.root, "second-result.json")
    release_file = Path.join(context.root, "release-health")

    on_exit(fn -> File.write(release_file, "release") end)

    first =
      Task.async(fn ->
        run_helper(context, "hold",
          attempt_id: @attempt_id,
          result_file: first_result,
          extra_env: [{"DALA_TEST_RELEASE", release_file}]
        )
      end)

    assert eventually(fn -> File.dir?(Path.join(context.root, ".update-dala.lock")) end)

    {second_status, second_result_payload} =
      run_helper(context, "success",
        attempt_id: "6ba7b811-9dad-11d1-80b4-00c04fd430c8",
        result_file: second_result
      )

    assert second_status != 0
    assert second_result_payload["success"] == false
    assert second_result_payload["message"] =~ "another update is already in progress"

    File.write!(release_file, "release")
    assert {0, first_payload} = Task.await(first, 5_000)
    assert first_payload["success"] == true
    assert current_tag(context.root) == "v99.0.0"
  end

  test "the activation lock spans rollback health checks", context do
    first_result = Path.join(context.root, "rollback-first-result.json")
    second_result = Path.join(context.root, "rollback-second-result.json")
    release_file = Path.join(context.root, "rollback-health")
    waiting_file = Path.join(context.root, "rollback-waiting")

    on_exit(fn -> File.write(release_file, "release") end)

    first =
      Task.async(fn ->
        run_helper(context, "rollback_hold",
          attempt_id: @attempt_id,
          result_file: first_result,
          extra_env: [
            {"DALA_TEST_RELEASE", release_file},
            {"DALA_TEST_ROLLBACK_WAITING", waiting_file}
          ]
        )
      end)

    assert eventually(fn -> File.exists?(waiting_file) end)
    assert current_tag(context.root) == "v0.25.17"

    {second_status, second_result_payload} =
      run_helper(context, "success",
        attempt_id: "6ba7b811-9dad-11d1-80b4-00c04fd430c8",
        result_file: second_result
      )

    assert second_status != 0
    assert second_result_payload["success"] == false
    assert second_result_payload["message"] =~ "another update is already in progress"

    File.write!(release_file, "release")
    assert {status, first_payload} = Task.await(first, 5_000)
    assert status != 0
    assert first_payload["success"] == false
    assert first_payload["rolled_back"] == true
    assert current_tag(context.root) == "v0.25.17"
  end

  defp run_helper(context, mode, options \\ []) do
    result_file = Keyword.get(options, :result_file, Path.join(context.root, "result.json"))
    attempt_id = Keyword.get(options, :attempt_id, @attempt_id)
    extra_env = Keyword.get(options, :extra_env, [])
    helper = Path.expand("../../../priv/unix/update-dala.sh", __DIR__)

    {_output, status} =
      System.cmd(
        "sh",
        [
          helper,
          context.root,
          "systemd",
          "dala",
          "v99.0.0",
          "v0.25.17",
          "99.0.0",
          "0.25.17",
          attempt_id,
          result_file,
          "http://127.0.0.1:4400/version",
          "2",
          "0"
        ],
        env:
          [
            {"PATH", context.bin <> ":" <> System.get_env("PATH", "")},
            {"DALA_TEST_ROOT", context.root},
            {"DALA_TEST_MODE", mode},
            {"DALA_TEST_EVENTS", Path.join(context.root, "events")},
            {"DALA_UPDATE_DELAY_SECONDS", "0"}
          ] ++ extra_env,
        stderr_to_stdout: true
      )

    payload = File.read!(result_file) |> Jason.decode!()
    {status, payload}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp current_tag(root) do
    root |> Path.join("current") |> File.read_link!() |> Path.basename()
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end
end
