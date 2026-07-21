defmodule Dala.Terminal.HolderWindowsTest do
  use ExUnit.Case, async: false

  alias Dala.Terminal.{Holder, Shell}

  @moduletag skip: not Dala.TestPlatform.windows?()

  test "browser-style carriage return executes a cmd command" do
    id = Ash.UUID.generate()
    shell = Dala.TestPlatform.shell()
    shell_options = Shell.spawn_options(shell)

    opts = [
      shell: shell,
      args: shell_options[:args],
      cwd: System.tmp_dir!(),
      env:
        [
          {"TERM", "xterm-256color"},
          {"COLORTERM", "truecolor"},
          {"WARP_CLI_AGENT_PROTOCOL_VERSION", "1"},
          {"WARP_CLIENT_VERSION", "dala"}
        ] ++ shell_options[:env],
      env_remove: ["TERM_PROGRAM", "WT_SESSION", "WT_PROFILE_ID"],
      rows: 24,
      cols: 80,
      history_lines: 1_000
    ]

    assert {:ok, socket, false} = Holder.attach_or_spawn(id, opts)

    on_exit(fn ->
      assert :ok = Holder.kill(id)
      wait_for_holder_exit(id)

      File.rm(Holder.socket_path(id))
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
    end)

    assert_receive {:tcp, ^socket, <<type, _hello::binary>>}, 2_000
    assert type == Holder.type_hello()
    Process.sleep(500)

    assert Holder.exists?(id),
           "holder exited: status=#{inspect(File.read(Holder.exit_path(id)))} " <>
             "screen=#{inspect(File.read(Holder.final_path(id)))}"

    assert :ok = :inet.setopts(socket, active: false)
    assert :ok = Holder.send_input(socket, "echo DALA_CR_OK\r")
    assert_output(socket, "DALA_CR_OK")
    assert Holder.exists?(id)
  end

  defp assert_output(socket, expected, acc \\ "") do
    assert {:ok, <<type, payload::binary>>} = :gen_tcp.recv(socket, 0, 5_000)

    acc = if type == Holder.type_output(), do: acc <> payload, else: acc

    unless String.contains?(acc, expected) do
      assert_output(socket, expected, acc)
    end
  end

  defp wait_for_holder_exit(id, attempts \\ 100)
  defp wait_for_holder_exit(id, 0), do: flunk("holder did not exit: #{Holder.socket_path(id)}")

  defp wait_for_holder_exit(id, attempts) do
    if Holder.exists?(id) do
      Process.sleep(20)
      wait_for_holder_exit(id, attempts - 1)
    end
  end
end
