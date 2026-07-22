defmodule Dala.Terminal.ProcessRequestTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.{Holder, Server}

  test "process requests carry a stable 64-bit request id" do
    {client, peer} = tcp_pair()
    on_exit(fn -> :gen_tcp.close(client) end)
    on_exit(fn -> :gen_tcp.close(peer) end)

    assert :ok = Holder.send_processes_req(client, 0x0102_0304_0506_0708)
    assert {:ok, <<0x16, 0x0102_0304_0506_0708::64>>} = :gen_tcp.recv(peer, 0, 1_000)
  end

  test "process responses resolve only the matching request" do
    matching_ref = make_ref()
    unrelated_ref = make_ref()
    matching_timer = Process.send_after(self(), :unexpected_matching_timeout, 60_000)
    unrelated_timer = Process.send_after(self(), :unexpected_unrelated_timeout, 60_000)

    state = %{
      socket: :holder_socket,
      pending_foregrounds: %{
        7 => %{from: {self(), matching_ref}, timer: matching_timer},
        8 => %{from: {self(), unrelated_ref}, timer: unrelated_timer}
      }
    }

    processes = Jason.encode!([%{"pid" => 42, "executable" => "codex.exe", "argv" => []}])

    assert {:noreply, next} =
             Server.handle_info(
               {:tcp, :holder_socket, <<Holder.type_processes(), 7::64, processes::binary>>},
               state
             )

    assert_receive {^matching_ref, {:ok, %{app: "codex"}}}
    refute_receive {^unrelated_ref, _reply}
    refute Map.has_key?(next.pending_foregrounds, 7)
    assert Map.has_key?(next.pending_foregrounds, 8)
    Process.cancel_timer(unrelated_timer)
  end

  test "timed out process requests are removed without shifting another response" do
    timed_out_ref = make_ref()
    pending_ref = make_ref()
    pending_timer = Process.send_after(self(), :unexpected_pending_timeout, 60_000)

    state = %{
      pending_foregrounds: %{
        3 => %{from: {self(), timed_out_ref}, timer: make_ref()},
        4 => %{from: {self(), pending_ref}, timer: pending_timer}
      }
    }

    assert {:noreply, next} = Server.handle_info({:foreground_timeout, 3}, state)
    assert_receive {^timed_out_ref, {:ok, %{app: "unknown", cmdline: ""}}}
    refute Map.has_key?(next.pending_foregrounds, 3)
    assert Map.has_key?(next.pending_foregrounds, 4)
    Process.cancel_timer(pending_timer)
  end

  defp tcp_pair do
    opts = [:binary, active: false, packet: 4]
    {:ok, listener} = :gen_tcp.listen(0, opts ++ [reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, opts)
    {:ok, peer} = :gen_tcp.accept(listener)
    :ok = :gen_tcp.close(listener)
    {client, peer}
  end
end
