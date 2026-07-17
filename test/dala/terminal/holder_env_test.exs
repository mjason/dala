defmodule Dala.Terminal.HolderEnvTest do
  # System.put_env is process-global — keep this module out of async.
  use ExUnit.Case, async: false

  alias Dala.Terminal.Holder
  alias Dala.Terminal.Server

  describe "Server.env_remove/0" do
    test "always scrubs host-terminal identity and server config names" do
      names = Server.env_remove()
      assert "TERM_PROGRAM" in names
      assert "PORT" in names
      assert "SECRET_KEY_BASE" in names
      assert "TOKEN_SIGNING_SECRET" in names
      assert "MIX_ENV" in names
    end

    test "scrubs whatever DALA_*/PHX_*/RELEASE_* variables are currently set" do
      System.put_env("DALA_TEST_LEAK_XYZ", "1")
      System.put_env("PHX_TEST_LEAK_XYZ", "1")
      System.put_env("RELEASE_TEST_LEAK_XYZ", "1")

      on_exit(fn ->
        System.delete_env("DALA_TEST_LEAK_XYZ")
        System.delete_env("PHX_TEST_LEAK_XYZ")
        System.delete_env("RELEASE_TEST_LEAK_XYZ")
      end)

      names = Server.env_remove()
      assert "DALA_TEST_LEAK_XYZ" in names
      assert "PHX_TEST_LEAK_XYZ" in names
      assert "RELEASE_TEST_LEAK_XYZ" in names
    end

    test "leaves the ordinary user environment alone" do
      names = Server.env_remove()
      refute "PATH" in names
      refute "HOME" in names
      refute "XDG_RUNTIME_DIR" in names
      refute "LANG" in names
    end
  end

  describe "holder spawn (end to end)" do
    @tag :tmp_dir
    test "a polluted variable does not reach the spawned shell", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "env.txt")
      id = "env-test-#{System.unique_integer([:positive])}"

      System.put_env("DALA_TEST_LEAK_E2E", "polluted")
      on_exit(fn -> System.delete_env("DALA_TEST_LEAK_E2E") end)

      assert {:ok, socket, false} =
               Holder.attach_or_spawn(id,
                 shell: "/bin/sh",
                 # tmp_dir carries the test name (spaces, parens) — quote it.
                 args: ["-c", "env > '#{out}'; exec sleep 60"],
                 cwd: tmp_dir,
                 env: [{"DALA_ENV_TEST_MARKER", "kept"}],
                 env_remove: Server.env_remove()
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

      # The scrubbed family is gone; explicitly-passed env still arrives.
      refute env_text =~ "DALA_TEST_LEAK_E2E"
      assert env_text =~ "DALA_ENV_TEST_MARKER=kept"
      # PATH survives — the scrub is surgical, not a clean-slate environment.
      assert env_text =~ "PATH="
    end
  end

  # The shell writes the file right after spawn; poll instead of sleeping a
  # fixed amount (guideline-compliant: bounded busy-wait on the observable).
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
