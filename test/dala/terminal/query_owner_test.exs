defmodule Dala.Terminal.QueryOwnerTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.Holder

  test "protocol-7 query ownership commands are explicit and byte exact" do
    {client, peer} = tcp_pair()
    on_exit(fn -> :gen_tcp.close(client) end)
    on_exit(fn -> :gen_tcp.close(peer) end)

    assert :ok = Holder.send_query_owner(client, true)
    assert {:ok, <<0x17, 1>>} = :gen_tcp.recv(peer, 0, 1_000)

    assert :ok = Holder.send_query_owner(client, false)
    assert {:ok, <<0x17, 0>>} = :gen_tcp.recv(peer, 0, 1_000)
    assert Holder.type_query_owner() == 0x17
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
