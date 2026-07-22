defmodule Dala.Terminal.ServerCwdTest do
  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server, Shell}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: Shell.default_shell()}, attrs))

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

  defp fake_bin(dir, name, script) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
    path
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

  @tag skip: Dala.TestPlatform.windows?()
  test "a slow mux cwd query does not block attach or size_info" do
    dir = Path.join(System.tmp_dir!(), "dala-server-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old_path = System.get_env("PATH")

    fake_bin(dir, "zellij", "sleep 2\nprintf 'layout { cwd \"/tmp\" }\\n'\n")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    # Force the poller down the mux path; the fake executable intentionally
    # takes longer than a user-facing synchronous call should ever wait.
    :sys.replace_state(pid, fn state -> %{state | mux: {:zellij, "slow"}} end)
    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})
    eventually(fn -> not is_nil(:sys.get_state(pid).cwd_poll_task) end)

    # A late result from a canceled worker must not mutate the live query.
    task_ref = :sys.get_state(pid).cwd_poll_task.ref

    send(pid, {
      make_ref(),
      {:cwd_poll_result, %{status: :mux, mux: {:zellij, "stale"}, cwd: "/tmp", osc7_cwd?: false}}
    })

    Process.sleep(20)
    assert :sys.get_state(pid).cwd_poll_task.ref == task_ref
    refute :sys.get_state(pid).mux == {:zellij, "stale"}

    started = System.monotonic_time(:millisecond)
    assert %{rows: 24, cols: 80} = Server.size_info(session.id)
    assert :claimed = Server.attach(session.id, self(), "cwd-test", nil, 24, 80)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 500, "synchronous terminal calls took #{elapsed}ms"

    # The shell can leave the mux while this slow query is in flight. Its OSC
    # 7 report arrives while state.mux still points at zellij; retain it, then
    # promote it as soon as the query reports that the mux disappeared.
    candidate =
      Path.join(
        System.tmp_dir!(),
        "dala-server-cwd-candidate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(candidate)
    on_exit(fn -> File.rm_rf!(candidate) end)

    state = :sys.get_state(pid)
    worker_pid = state.cwd_poll_task.pid
    socket = state.socket
    send(pid, {:tcp, socket, <<Holder.type_cwd(), candidate::binary>>})

    eventually(fn -> :sys.get_state(pid).osc7_cwd_candidate == candidate end)
    refute :sys.get_state(pid).cwd == candidate

    send(pid, {
      task_ref,
      {:cwd_poll_result, %{status: :confirmed_no_mux, mux: nil, cwd: nil, osc7_cwd?: false}}
    })

    eventually(fn ->
      state = :sys.get_state(pid)
      state.mux == nil and state.cwd == candidate
    end)

    Process.exit(worker_pid, :kill)
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

  @tag skip: Dala.TestPlatform.windows?()
  test "a transient mux query failure does not promote an old OSC 7 candidate" do
    dir =
      Path.join(System.tmp_dir!(), "dala-server-cwd-fail-#{System.unique_integer([:positive])}")

    candidate = Path.join(dir, "candidate")
    File.mkdir_p!(candidate)
    old_path = System.get_env("PATH")

    fake_bin(dir, "zellij", "exit 1\n")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    initial_cwd = :sys.get_state(pid).cwd
    :sys.replace_state(pid, fn state -> %{state | mux: {:zellij, "transient"}} end)

    state = :sys.get_state(pid)
    send(pid, {:tcp, state.socket, <<Holder.type_cwd(), candidate::binary>>})
    eventually(fn -> :sys.get_state(pid).osc7_cwd_candidate == candidate end)
    assert :sys.get_state(pid).cwd == initial_cwd

    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})

    eventually(fn ->
      state = :sys.get_state(pid)
      is_nil(state.cwd_poll_task) and is_nil(state.mux)
    end)

    # zellij returned an error, which is not proof that the shell left it.
    assert :sys.get_state(pid).cwd == initial_cwd

    latest_candidate = Path.join(dir, "latest-candidate")
    File.mkdir_p!(latest_candidate)
    state = :sys.get_state(pid)
    send(pid, {:tcp, state.socket, <<Holder.type_cwd(), latest_candidate::binary>>})

    eventually(fn -> :sys.get_state(pid).osc7_cwd_candidate == latest_candidate end)

    # Discovery has not yet confirmed mux exit. A fresh OSC 7 report updates
    # the candidate, but cannot become authoritative during this uncertainty.
    assert :sys.get_state(pid).cwd == initial_cwd

    # The following mux discovery pass can confirm that no mux client remains;
    # only that result may promote the top-level shell's OSC 7 candidate.
    %{cwd_poll_timer: {confirm_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, confirm_ref})
    eventually(fn -> :sys.get_state(pid).cwd == latest_candidate end)
  end

  @tag skip: Dala.TestPlatform.windows?()
  test "a cwd poll starts when upgrading state without the cwd_poll_task key" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dala-server-cwd-upgrade-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    old_path = System.get_env("PATH")

    fake_bin(dir, "zellij", "sleep 2\nexit 1\n")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    :sys.replace_state(pid, fn state ->
      state
      |> Map.delete(:cwd_poll_task)
      |> Map.put(:mux, {:zellij, "slow-upgrade"})
    end)

    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})

    eventually(fn -> is_map(Map.get(:sys.get_state(pid), :cwd_poll_task)) end)
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

  @tag skip: Dala.TestPlatform.windows?()
  test "stopping a session terminates an in-flight cwd worker" do
    dir =
      Path.join(System.tmp_dir!(), "dala-server-cwd-stop-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    old_path = System.get_env("PATH")
    fake_bin(dir, "zellij", "sleep 2\nprintf 'layout { cwd \"/tmp\" }\\n'\n")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)
    :sys.replace_state(pid, fn state -> %{state | mux: {:zellij, "slow"}} end)
    %{cwd_poll_timer: {poll_ref, _timer}} = :sys.get_state(pid)
    send(pid, {:poll_cwd, poll_ref})
    eventually(fn -> not is_nil(:sys.get_state(pid).cwd_poll_task) end)

    worker_pid = :sys.get_state(pid).cwd_poll_task.pid
    Server.shutdown_and_wait(session.id)
    refute Process.alive?(worker_pid)
  end
end
