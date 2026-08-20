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
    @tag :tmp_dir
    test "runs the command and delivers stdout and exit status", %{tmp_dir: tmp_dir} do
      command =
        if match?({:win32, :nt}, :os.type()) do
          [windows_script(tmp_dir, "stdout.cmd", "@echo hi\r\n")]
        else
          ["echo", "hi"]
        end

      port = ShellPort.open(command, "/dev/null")
      {data, status} = collect_port(port)
      assert normalize_newlines(data) == "hi\n"
      assert status == 0
    end

    @tag :tmp_dir
    test "argv words with quotes and spaces survive the shell round trip", %{tmp_dir: tmp_dir} do
      command =
        if match?({:win32, :nt}, :os.type()) do
          [windows_script(tmp_dir, "argv.cmd", "@echo %~1\r\n"), "it's a 'test'"]
        else
          ["echo", "it's a 'test'"]
        end

      port = ShellPort.open(command, "/dev/null")
      {data, status} = collect_port(port)
      assert normalize_newlines(data) == "it's a 'test'\n"
      assert status == 0
    end

    @tag :tmp_dir
    test "stderr goes to the given file, not the stream", %{tmp_dir: tmp_dir} do
      stderr =
        Path.join(System.tmp_dir!(), "dala-shellport-#{System.unique_integer([:positive])}.log")

      on_exit(fn -> File.rm(stderr) end)

      command =
        if match?({:win32, :nt}, :os.type()) do
          [windows_script(tmp_dir, "stderr.cmd", "@echo out\r\n@echo err 1>&2\r\n")]
        else
          ["/bin/sh", "-c", "echo out; echo err >&2"]
        end

      port = ShellPort.open(command, stderr)
      {data, status} = collect_port(port)

      assert status == 0,
             "unexpected exit; stdout=#{inspect(data)} stderr=#{inspect(File.read!(stderr))}"

      assert normalize_newlines(data) == "out\n"
      assert stderr |> File.read!() |> String.trim() == "err"
    end

    test "exec makes the program itself the port's os_pid" do
      if match?({:win32, :nt}, :os.type()) do
        # PowerShell is intentionally the wrapper on Windows; process identity
        # is covered by the holder smoke test instead of /proc semantics.
        assert true
      else
        port = ShellPort.open(["cat"], "/dev/null")
        Port.command(port, "ping\n")
        assert_receive {^port, {:data, "ping\n"}}, 2_000
        assert {:os_pid, os_pid} = Port.info(port, :os_pid)
        assert File.read!("/proc/#{os_pid}/comm") == "cat\n"
        ShellPort.close(port)
      end
    end
  end

  describe "close/1" do
    test "nil is a no-op" do
      assert ShellPort.close(nil) == :ok
    end

    test "kills the process and closes the port" do
      command =
        if match?({:win32, :nt}, :os.type()),
          do: [windows_powershell(), "-NoProfile", "-Command", "Start-Sleep -Seconds 60"],
          else: ["cat"]

      port = ShellPort.open(command, "/dev/null")
      assert ShellPort.close(port) == :ok
      assert Port.info(port) == nil
    end

    test "closing an already-dead port does not raise" do
      command =
        if match?({:win32, :nt}, :os.type()) do
          [windows_powershell(), "-NoProfile", "-Command", "exit 0"]
        else
          ["true"]
        end

      port = ShellPort.open(command, "/dev/null")
      timeout = if match?({:win32, :nt}, :os.type()), do: 10_000, else: 2_000
      assert_receive {^port, {:exit_status, 0}}, timeout
      assert ShellPort.close(port) == :ok
      assert ShellPort.close(port) == :ok
    end
  end

  describe "run/4" do
    @tag :tmp_dir
    test "returns captured output and exit status before the deadline", %{tmp_dir: tmp_dir} do
      command =
        if match?({:win32, :nt}, :os.type()) do
          [windows_script(tmp_dir, "run.cmd", "@echo done\r\n@exit /B 7\r\n")]
        else
          ["/bin/sh", "-c", "echo done; exit 7"]
        end

      assert {:ok, output, 7} = ShellPort.run(command, "/dev/null", 2_000)
      assert normalize_newlines(output) == "done\n"
    end

    test "kills a command tree when the deadline expires" do
      command =
        if match?({:win32, :nt}, :os.type()),
          do: [windows_powershell(), "-NoProfile", "-Command", "Start-Sleep -Seconds 60"],
          else: ["sleep", "60"]

      assert {:error, :timeout} = ShellPort.run(command, "/dev/null", 100)
    end
  end

  defp normalize_newlines(data), do: String.replace(data, "\r\n", "\n")

  defp collect_port(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      2_000 -> flunk("port did not exit; output so far: #{inspect(output)}")
    end
  end

  defp windows_powershell do
    System.find_executable("powershell.exe") || System.find_executable("powershell") ||
      "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  end

  defp windows_script(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.write!(path, contents)
    path
  end
end
