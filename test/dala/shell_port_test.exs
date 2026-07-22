defmodule Dala.ShellPortTest do
  use ExUnit.Case, async: false

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

  describe "port_options/1" do
    test "hides Windows background helpers while preserving caller options" do
      options = ShellPort.port_options([{:line, 4096}])

      assert {:line, 4096} in options

      if windows?() do
        assert :hide in options
      else
        refute :hide in options
      end
    end
  end

  describe "open/3" do
    test "runs the command and delivers stdout and exit status" do
      port = ShellPort.open(output_command("hi"), null_device())
      assert_data_contains(port, "hi")
      assert_receive {^port, {:exit_status, 0}}, 2_000
    end

    test "argv words with quotes and spaces survive the shell round trip" do
      port = ShellPort.open(output_command("it's a 'test'"), null_device())
      assert_data_contains(port, "it's a 'test'")
      assert_receive {^port, {:exit_status, 0}}, 2_000
    end

    test "stderr goes to the given file, not the stream" do
      stderr =
        Path.join(System.tmp_dir!(), "dala-shellport-#{System.unique_integer([:positive])}.log")

      on_exit(fn -> File.rm(stderr) end)

      port = ShellPort.open(stdout_stderr_command(), stderr)
      assert_data_contains(port, "out")
      assert_receive {^port, {:exit_status, 0}}, 2_000
      assert File.read!(stderr) =~ "err"
    end

    test "exec makes the program itself the port's os_pid" do
      port = ShellPort.open(interactive_command(), null_device())
      # cat echoing input back proves the exec has happened before we look.
      Port.command(port, "ping\n")
      assert_data_contains(port, "ping")

      assert {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert is_integer(os_pid) and os_pid > 0
      ShellPort.close(port)
    end
  end

  describe "close/1" do
    test "nil is a no-op" do
      assert ShellPort.close(nil) == :ok
    end

    test "kills the process and closes the port" do
      port = ShellPort.open(interactive_command(), null_device())
      assert ShellPort.close(port) == :ok
      assert Port.info(port) == nil
    end

    test "closing an already-dead port does not raise" do
      port = ShellPort.open(success_command(), null_device())
      assert_receive {^port, {:exit_status, 0}}, 2_000
      assert ShellPort.close(port) == :ok
      assert ShellPort.close(port) == :ok
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
  defp null_device, do: if(windows?(), do: "NUL", else: "/dev/null")

  defp output_command(text) do
    if windows?(), do: ["cmd.exe", "/D", "/S", "/C", "echo #{text}"], else: ["echo", text]
  end

  defp stdout_stderr_command do
    if windows?(),
      do: [
        System.find_executable("powershell.exe") || "powershell.exe",
        "-NoProfile",
        "-Command",
        "[Console]::Out.WriteLine('out'); [Console]::Error.WriteLine('err')"
      ],
      else: ["/bin/sh", "-c", "echo out; echo err >&2"]
  end

  defp interactive_command do
    if windows?(), do: ["cmd.exe", "/D", "/Q"], else: ["cat"]
  end

  defp success_command do
    if windows?(), do: ["cmd.exe", "/D", "/C", "exit", "0"], else: ["true"]
  end

  defp assert_data_contains(port, expected, data \\ "", attempts \\ 20)

  defp assert_data_contains(_port, expected, data, 0) do
    flunk("port output never contained #{inspect(expected)}; got #{inspect(data)}")
  end

  defp assert_data_contains(port, expected, data, attempts) do
    receive do
      {^port, {:data, chunk}} ->
        combined = data <> chunk

        if String.contains?(combined, expected),
          do: :ok,
          else: assert_data_contains(port, expected, combined, attempts - 1)

      {^port, {:exit_status, status}} ->
        flunk("port exited with #{status} before output contained #{inspect(expected)}")
    after
      200 -> assert_data_contains(port, expected, data, attempts - 1)
    end
  end
end
