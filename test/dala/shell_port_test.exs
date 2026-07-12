defmodule Dala.ShellPortTest do
  use ExUnit.Case, async: true

  alias Dala.ShellPort

  describe "escape/1" do
    test "wraps a plain word in single quotes" do
      assert ShellPort.escape("hello") == "'hello'"
    end

    test "escapes embedded single quotes" do
      assert ShellPort.escape("it's") == "'it'\\''s'"
    end
  end

  describe "shell_command/2" do
    test "execs the escaped argv and redirects stderr" do
      assert ShellPort.shell_command(["prog", "--flag"], "/tmp/err.log") ==
               "'exec' 'prog' '--flag' 2> '/tmp/err.log'"
    end
  end

  describe "open/3" do
    test "runs the command and delivers stdout and exit status" do
      port = ShellPort.open(["echo", "hi"], "/dev/null")
      assert_receive {^port, {:data, "hi\n"}}, 2_000
      assert_receive {^port, {:exit_status, 0}}, 2_000
    end

    test "argv words with quotes and spaces survive the shell round trip" do
      port = ShellPort.open(["echo", "it's a 'test'"], "/dev/null")
      assert_receive {^port, {:data, "it's a 'test'\n"}}, 2_000
      assert_receive {^port, {:exit_status, 0}}, 2_000
    end

    test "stderr goes to the given file, not the stream" do
      stderr =
        Path.join(System.tmp_dir!(), "dala-shellport-#{System.unique_integer([:positive])}.log")

      on_exit(fn -> File.rm(stderr) end)

      port = ShellPort.open(["/bin/sh", "-c", "echo out; echo err >&2"], stderr)
      assert_receive {^port, {:data, "out\n"}}, 2_000
      assert_receive {^port, {:exit_status, 0}}, 2_000
      assert File.read!(stderr) == "err\n"
    end

    test "exec makes the program itself the port's os_pid" do
      port = ShellPort.open(["cat"], "/dev/null")
      # cat echoing input back proves the exec has happened before we look.
      Port.command(port, "ping\n")
      assert_receive {^port, {:data, "ping\n"}}, 2_000

      assert {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert File.read!("/proc/#{os_pid}/comm") == "cat\n"
      ShellPort.close(port)
    end
  end

  describe "close/1" do
    test "nil is a no-op" do
      assert ShellPort.close(nil) == :ok
    end

    test "kills the process and closes the port" do
      port = ShellPort.open(["cat"], "/dev/null")
      assert ShellPort.close(port) == :ok
      assert Port.info(port) == nil
    end

    test "closing an already-dead port does not raise" do
      port = ShellPort.open(["true"], "/dev/null")
      assert_receive {^port, {:exit_status, 0}}, 2_000
      assert ShellPort.close(port) == :ok
      assert ShellPort.close(port) == :ok
    end
  end
end
