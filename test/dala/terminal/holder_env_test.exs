defmodule Dala.Terminal.HolderEnvTest do
  # Spawns a real holder + shell.
  use ExUnit.Case, async: false

  alias Dala.Terminal.Holder

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

      assert {:ok, socket, false} =
               Holder.attach_or_spawn(id,
                 shell: "/bin/sh",
                 # tmp_dir carries the test name (spaces, parens) — quote it.
                 args: ["-c", "env > '#{out}'; exec sleep 60"],
                 cwd: tmp_dir,
                 env: [{"DALA_ENV_TEST_MARKER", "kept"}]
               )

      on_exit(fn ->
        with {:ok, kill_socket} <- Holder.connect(id) do
          Holder.send_kill(kill_socket)
          :gen_tcp.close(kill_socket)
        end

        File.rm(Holder.socket_path(id))
        File.rm(Holder.exit_path(id))
        File.rm(Holder.final_path(id))
        File.rm(Holder.text_final_path(id))
        # The holder daemon's stdio log sits next to the socket.
        File.rm(Holder.socket_path(id) <> ".log")
      end)

      env_text = await_file(out)
      :gen_tcp.close(socket)

      # Inherited environment arrives untouched; explicit spawn env arrives.
      assert env_text =~ "DALA_TEST_PASSTHROUGH_E2E=inherited"
      assert env_text =~ "DALA_ENV_TEST_MARKER=kept"
      assert env_text =~ "PATH="
      assert env_text =~ "HOME="
    end
  end

  defp await_file(path, attempts \\ 200) do
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
end
