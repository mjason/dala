defmodule Dala.Terminal.ServerCwdTest do
  @moduledoc """
  cwd tracking. A shell that reports OSC 7 is authoritative about where it is;
  the poll only covers shells that do not, and it runs in a throwaway worker so
  a filesystem stall can never reach the session's synchronous calls.
  """

  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, attrs))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      id = to_string(session.id)
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
      File.rm(Holder.socket_path(id) <> ".log")
    end)

    session
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
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

  defp eventually(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  # A worker that never answers — what a /proc read against a wedged mount
  # looks like from this server's point of view.
  defp stall_cwd_worker(pid) do
    owner = self()

    :sys.replace_state(pid, fn state ->
      worker = spawn(fn -> receive do: (:never -> :ok) end)
      monitor = Process.monitor(worker)
      send(owner, {:worker, worker})

      %{
        state
        | cwd_poll_task: %{
            pid: worker,
            ref: make_ref(),
            monitor: monitor,
            started_at: System.monotonic_time(:millisecond)
          }
      }
    end)

    receive do
      {:worker, worker} -> worker
    after
      1_000 -> flunk("worker was never injected")
    end
  end

  test "a stalled cwd worker does not block attach or size_info" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    worker = stall_cwd_worker(pid)
    task_ref = :sys.get_state(pid).cwd_poll_task.ref

    # A late result from a canceled/older query must never settle the live one.
    send(pid, {make_ref(), {:cwd_poll_result, %{cwd: "/tmp"}}})
    Process.sleep(20)
    assert :sys.get_state(pid).cwd_poll_task.ref == task_ref

    started = System.monotonic_time(:millisecond)
    assert %{rows: 24, cols: 80} = Server.size_info(session.id)
    assert :claimed = Server.attach(session.id, self(), "cwd-test", nil, 24, 80)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 500, "synchronous terminal calls took #{elapsed}ms"

    Process.exit(worker, :kill)
  end

  test "an OSC 7 report owns the cwd and retires /proc polling" do
    reported = tmp_dir("dala-server-cwd-osc7")
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    socket = :sys.get_state(pid).socket
    send(pid, {:tcp, socket, <<Holder.type_cwd()>> <> reported})

    eventually(fn ->
      state = :sys.get_state(pid)
      state.cwd == reported and state.osc7_cwd?
    end)

    # The next poll must not walk this back to the shell process's own cwd.
    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})

    eventually(fn -> is_nil(:sys.get_state(pid).cwd_poll_task) end)
    assert :sys.get_state(pid).cwd == reported
  end

  test "visibility changes keep a fast visible cadence and back off when hidden" do
    session = create_session!()
    pid = Server.whereis(session.id)

    Server.set_visibility(session.id, self(), "cwd-visibility", true)

    eventually(fn ->
      state = :sys.get_state(pid)

      MapSet.member?(state.visible_clients, self()) and
        (not is_nil(state.cwd_poll_task) or not is_nil(state.cwd_poll_timer))
    end)

    state = :sys.get_state(pid)

    if state.cwd_poll_timer do
      {_ref, timer} = state.cwd_poll_timer
      remaining = Process.read_timer(timer)
      assert remaining == false or remaining <= 2_000
    end

    Server.set_visibility(session.id, self(), "cwd-visibility", false)

    eventually(fn ->
      state = :sys.get_state(pid)
      not MapSet.member?(state.visible_clients, self()) and not is_nil(state.cwd_poll_timer)
    end)

    {_ref, timer} = :sys.get_state(pid).cwd_poll_timer
    remaining = Process.read_timer(timer)
    assert is_integer(remaining) and remaining >= 20_000
  end

  test "a cwd poll starts when upgrading state without the cwd_poll_task key" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    :sys.replace_state(pid, fn state -> Map.delete(state, :cwd_poll_task) end)

    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})

    # The poll path has to tolerate a state map from an older release and put
    # the key back rather than crash the session.
    eventually(fn -> Map.has_key?(:sys.get_state(pid), :cwd_poll_task) end)
    assert Process.alive?(pid)
  end

  test "terminate cleans up a copied old state without the cwd_poll_task key" do
    session = create_session!()
    pid = Server.whereis(session.id)
    {fake_socket, peer} = tcp_pair()

    old_state =
      pid
      |> :sys.get_state()
      |> Map.delete(:cwd_poll_task)
      |> Map.merge(%{socket: fake_socket, cwd_poll_timer: nil})

    try do
      assert :ok = Server.terminate(:normal, old_state)
      assert {:error, :closed} = :gen_tcp.recv(peer, 0, 1_000)
    after
      :gen_tcp.close(fake_socket)
      :gen_tcp.close(peer)
    end
  end

  test "stopping a session terminates an in-flight cwd worker" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    worker = stall_cwd_worker(pid)

    Server.shutdown_and_wait(session.id)
    refute Process.alive?(worker)
  end
end
