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

      {shell, args} = test_shell(out)

      assert {:ok, socket, false} =
               Holder.attach_or_spawn(id,
                 shell: shell,
                 args: args,
                 cwd: tmp_dir,
                 env: [{"DALA_ENV_TEST_MARKER", "kept"}]
               )

      on_exit(fn ->
        with {:ok, kill_socket} <- Holder.connect(id) do
          Holder.send_kill(kill_socket)
          :gen_tcp.close(kill_socket)
        end

        File.rm(Holder.socket_path(id))
        File.rm(Holder.token_path(id))
        File.rm(Holder.exit_path(id))
        File.rm(Holder.final_path(id))
        File.rm(Holder.text_final_path(id))
        # The holder daemon's stdio log sits next to the socket.
        File.rm(Holder.socket_path(id) <> ".log")
      end)

      env_text = await_file(out)

      # Inherited environment arrives untouched; explicit spawn env arrives.
      assert env_text =~ "DALA_TEST_PASSTHROUGH_E2E=inherited"
      assert env_text =~ "DALA_ENV_TEST_MARKER=kept"
      assert env_text =~ "PATH="
      assert env_text =~ "HOME="
      refute env_text =~ "DALA_HOLDER_DETACHED="

      exit_type = Holder.type_exit()
      assert :ok = Holder.send_kill(socket)
      assert_receive {:tcp, ^socket, <<^exit_type, _status::32>>}, 2_000
      :gen_tcp.close(socket)
    end

    if match?({:win32, :nt}, :os.type()) do
      @tag :tmp_dir
      test "a naturally exiting shell reports its status and stops the holder", %{
        tmp_dir: tmp_dir
      } do
        id = "natural-exit-test-#{System.unique_integer([:positive])}"

        shell =
          System.find_executable("pwsh") ||
            System.find_executable("powershell") || "powershell.exe"

        assert {:ok, socket, false} =
                 Holder.attach_or_spawn(id,
                   shell: shell,
                   args: [
                     "-NoProfile",
                     "-NonInteractive",
                     "-Command",
                     "Start-Sleep -Milliseconds 500; exit 7"
                   ],
                   cwd: tmp_dir
                 )

        holder_pid = windows_listener_owner!(Holder.socket_path(id))
        exit_type = Holder.type_exit()

        assert_receive {:tcp, ^socket, <<^exit_type, 7::32>>}, 3_000
        :gen_tcp.close(socket)

        assert holder_stopped?(holder_pid)
        refute File.exists?(Holder.socket_path(id))
        assert Holder.take_exit_status(id) == 7

        File.rm(Holder.token_path(id))
        File.rm(Holder.final_path(id))
        File.rm(Holder.text_final_path(id))
        File.rm(Holder.socket_path(id) <> ".log")
      end
    end
  end

  defp windows_listener_owner!(path) do
    port =
      path
      |> File.read!()
      |> String.trim()
      |> String.split(":", parts: 2)
      |> List.last()

    {netstat, 0} = System.cmd("netstat.exe", ["-ano", "-p", "tcp"])

    netstat
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [_protocol, local, _remote, "LISTENING", pid] ->
          if String.ends_with?(local, ":" <> port), do: String.to_integer(pid)

        _other ->
          nil
      end
    end)
    |> case do
      nil -> flunk("no holder process is listening on port #{port}")
      pid -> pid
    end
  end

  defp holder_stopped?(pid, attempts \\ 30)
  defp holder_stopped?(_pid, 0), do: false

  defp holder_stopped?(pid, attempts) do
    {tasklist, 0} =
      System.cmd("tasklist.exe", ["/FI", "PID eq #{pid}", "/FO", "CSV", "/NH"])

    if tasklist =~ ~s(,"#{pid}",) do
      holder_stopped?(pid, attempts - 1)
    else
      true
    end
  end

  defp test_shell(out) do
    if match?({:win32, :nt}, :os.type()) do
      shell =
        System.find_executable("pwsh") || System.find_executable("powershell") || "powershell.exe"

      script =
        "Get-ChildItem env: | ForEach-Object { \"$($_.Name)=$($_.Value)\" } | " <>
          "Set-Content -LiteralPath '#{String.replace(out, "'", "''")}' ; " <>
          "Start-Sleep -Seconds 10"

      {shell, ["-NoProfile", "-NonInteractive", "-Command", script]}
    else
      {"/bin/sh", ["-c", "env > '#{out}'; exec sleep 60"]}
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
