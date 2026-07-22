defmodule Dala.Terminal.HolderEnvTest do
  # Spawns a real holder + shell.
  use ExUnit.Case, async: false

  alias Dala.Terminal.{Holder, Shell}

  # A Windows holder is launched through the WMI broker, so a busy hosted
  # runner can take several seconds to get the shell to its first command.
  # Keep the fast local timeout on Unix while giving that startup path a
  # bounded, explicit budget instead of making the test race the broker.
  @file_wait_attempts if(Dala.TestPlatform.windows?(), do: 1_500, else: 200)

  # POLICY (user decision): dala does NOT touch the environment it passes to
  # shells. The server process is kept clean at the SOURCE — configuration
  # lives in config.jsonc and secrets in the data dir, so there is nothing
  # dala-specific in the process environment to begin with. No scrubbing,
  # no allowlist: what the server inherited passes through, plus dala's own
  # explicit spawn additions (TERM & friends).

  describe "holder spawn (end to end)" do
    @tag :tmp_dir
    test "the environment passes through untouched, plus explicit additions", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "env.txt")
      id = "env-test-#{System.unique_integer([:positive])}"

      System.put_env("DALA_TEST_PASSTHROUGH_E2E", "inherited")
      on_exit(fn -> System.delete_env("DALA_TEST_PASSTHROUGH_E2E") end)

      shell = Dala.TestPlatform.shell()
      shell_options = Shell.spawn_options(shell)

      assert {:ok, socket, false} =
               Holder.attach_or_spawn(id,
                 shell: shell,
                 args: shell_options[:args],
                 cwd: tmp_dir,
                 env: [{"DALA_ENV_TEST_MARKER", "kept"} | shell_options[:env]],
                 env_remove: Keyword.get(shell_options, :env_remove, [])
               )

      on_exit(fn ->
        assert :ok = Holder.kill(id)
        wait_for_holder_exit(id)
        File.rm(Holder.socket_path(id))
        File.rm(Holder.exit_path(id))
        File.rm(Holder.final_path(id))
        File.rm(Holder.text_final_path(id))
        # The holder daemon's stdio log sits next to the socket.
        File.rm(Holder.socket_path(id) <> ".log")
      end)

      assert :ok = Holder.send_input(socket, capture_env_command(out))
      env = out |> await_file(@file_wait_attempts) |> parse_env()
      :gen_tcp.close(socket)

      # Inherited environment arrives untouched; explicit spawn env arrives.
      assert env["dala_test_passthrough_e2e"] == "inherited"
      assert env["dala_env_test_marker"] == "kept"
      assert Map.has_key?(env, "path")
      assert Map.has_key?(env, if(Dala.TestPlatform.windows?(), do: "userprofile", else: "home"))
    end
  end

  defp capture_env_command(path) do
    if Dala.TestPlatform.windows?() do
      ~s(set > "#{String.replace(path, "/", "\\")}"\r)
    else
      escaped = String.replace(path, "'", "'\\''")
      "env > '#{escaped}'\r"
    end
  end

  defp parse_env(contents) do
    Map.new(String.split(contents, ~r/\R/, trim: true), fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {String.downcase(key), value}
    end)
  end

  defp await_file(path, attempts) do
    case File.read(path) do
      {:ok, contents} when contents != "" ->
        contents

      _other when attempts > 0 ->
        Process.sleep(10)
        await_file(path, attempts - 1)

      _other ->
        flunk("shell never wrote #{path}")
    end
  end

  defp wait_for_holder_exit(id, attempts \\ 200)
  defp wait_for_holder_exit(id, 0), do: flunk("holder did not exit: #{Holder.socket_path(id)}")

  defp wait_for_holder_exit(id, attempts) do
    if Holder.exists?(id) do
      receive do
      after
        10 -> wait_for_holder_exit(id, attempts - 1)
      end
    end
  end
end
