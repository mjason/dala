defmodule Dala.Terminal.SessionTest do
  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: test_shell()}, attrs))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      File.rm(Holder.exit_path(to_string(session.id)))
      File.rm(Holder.final_path(to_string(session.id)))
      File.rm(Holder.text_final_path(to_string(session.id)))
    end)

    session
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

  defp recv_packets(socket, count, timeout \\ 1_000) do
    Enum.map(1..count, fn _index ->
      assert {:ok, packet} = :gen_tcp.recv(socket, 0, timeout)
      packet
    end)
  end

  defp disable_query_owner_for_test(state) do
    case Map.get(state, :query_owner_command) do
      %{timer: timer} -> Process.cancel_timer(timer)
      _ -> :ok
    end

    Map.merge(state, %{
      query_owner_command: nil,
      query_owner_phase: :disabled,
      query_owner_enabled?: false,
      query_owner_negotiable?: false
    })
  end

  defp windows?, do: Dala.TestPlatform.windows?()

  defp test_shell, do: Dala.TestPlatform.shell()

  defp cwd_marker_command,
    do: if(windows?(), do: "echo marker-%CD%\r", else: "echo marker-$PWD\r")

  defp arithmetic_command,
    do: if(windows?(), do: "set /a 40 + 2\r", else: "echo dala-$((40 + 2))\r")

  defp raw_output(session_id, bytes, hold_ms \\ 2_000) do
    encoded = Base.encode64(bytes)

    command =
      if windows?() do
        Dala.TestPlatform.node_eval_command(
          "process.stdin.setRawMode(true);process.stdin.resume();" <>
            "process.stdout.write(Buffer.from('#{encoded}','base64'));" <>
            "setTimeout(()=>process.exit(0),#{hold_ms})"
        )
      else
        "printf %s '#{encoded}' | base64 -d"
      end

    Server.send_sequence(session_id, [{command, 50}, {"\r", 0}])
  end

  defp queue_commands(path) do
    if windows?() do
      quoted = String.replace(path, "\"", "\"\"")

      {
        [
          {"<nul set /p \"=A\" > \"#{quoted}\" & ", 150},
          {"<nul set /p \"=B\" >> \"#{quoted}\"\r", 0}
        ],
        [{"<nul set /p \"=C\" >> \"#{quoted}\"\r", 0}]
      }
    else
      {
        [{"printf A > #{path};", 150}, {"printf B >> #{path}\r", 0}],
        [{"printf C >> #{path}\r", 0}]
      }
    end
  end

  defp await_exit(session_id) do
    ref = Process.monitor(Server.whereis(session_id))
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 8_000
  end

  defp eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  # The holder-side emulator's synthesized screen for a running session.
  defp repaint_text(session_id) do
    Server.request_repaint(session_id, self())

    receive do
      {:repaint, data, _seq, _history_loaded} -> data
    after
      5_000 -> flunk("no repaint from holder")
    end
  end

  test "create applies defaults and spawns a live shell" do
    session = create_session!()

    assert session.status == :running
    assert session.name == "Terminal"
    assert session.cwd != nil
    assert session.scrollback_limit == 10_000
    assert Server.alive?(session.id)
  end

  test "query-owner ACK flushes earlier batched output before capabilities" do
    session = create_session!()
    server = Server.whereis(session.id)
    original_socket = :sys.get_state(server).socket
    {fake_socket, peer} = tcp_pair()
    topic = "terminal:#{session.id}"

    _ = Server.size_info(session.id)
    :ok = :inet.setopts(original_socket, active: false)
    Phoenix.PubSub.subscribe(Dala.PubSub, topic)

    timer = Process.send_after(server, :flush_output, 60_000)

    :sys.replace_state(server, fn state ->
      if state.out_timer, do: Process.cancel_timer(state.out_timer)

      %{
        state
        | socket: fake_socket,
          holder_proto: 7,
          query_owner_phase: :enabling,
          query_owner_enabled?: false,
          query_owner_negotiable?: true,
          query_clients: %{},
          out_buf: ["old-owner-query"],
          out_timer: timer
      }
    end)

    try do
      send(server, {:tcp, fake_socket, <<Holder.type_query_owner(), 1>>})
      _ = Server.size_info(session.id)

      assert_receive %Phoenix.Socket.Broadcast{} = first, 1_000
      assert first.event == "output"
      assert Base.decode64!(first.payload.data) == "old-owner-query"

      assert_receive %Phoenix.Socket.Broadcast{} = second, 1_000
      assert second.event == "terminal_capabilities"
      assert second.payload.holder_query_owner
    after
      if Process.alive?(server) do
        current = :sys.get_state(server)
        if current.out_timer, do: Process.cancel_timer(current.out_timer)

        :sys.replace_state(server, fn state ->
          %{state | socket: original_socket, out_buf: [], out_timer: nil}
        end)

        :ok = :inet.setopts(original_socket, active: true)
      end

      :gen_tcp.close(fake_socket)
      :gen_tcp.close(peer)
    end
  end

  test "a full repaint queue rejects targeted and all-client work without shifting FIFO" do
    session = create_session!()
    server = Server.whereis(session.id)
    original_socket = :sys.get_state(server).socket
    {fake_socket, peer} = tcp_pair()
    request_ref = make_ref()

    full_queue =
      Enum.reduce(1..64, :queue.new(), fn _index, queue ->
        :queue.in({:all_clients, 0}, queue)
      end)

    :ok = :inet.setopts(original_socket, active: false)

    :sys.replace_state(server, fn state ->
      state
      |> disable_query_owner_for_test()
      |> Map.merge(%{socket: fake_socket, pending_repaints: full_queue})
    end)

    try do
      assert :ok = Server.request_repaint(session.id, self(), history: :screen, ref: request_ref)
      _ = Server.size_info(session.id)

      assert_receive {:repaint, "", _seq, false, ^request_ref}, 1_000
      assert :queue.len(:sys.get_state(server).pending_repaints) == 64

      # A takeover normally requests one all-client snapshot. At the same hard
      # limit it must not write another holder frame or grow the BEAM queue.
      Server.claim_size(session.id, self(), "queue-test", "queue-device", 24, 80)
      _ = Server.size_info(session.id)

      assert :queue.len(:sys.get_state(server).pending_repaints) == 64
    after
      if Process.alive?(server) do
        :sys.replace_state(server, fn state ->
          %{state | socket: original_socket, pending_repaints: :queue.new()}
        end)

        :ok = :inet.setopts(original_socket, active: true)
      end

      :gen_tcp.close(fake_socket)
      :gen_tcp.close(peer)
    end
  end

  test "a full repaint queue coalesces resize repairs and sends one when a slot opens" do
    session = create_session!()
    server = Server.whereis(session.id)
    original_socket = :sys.get_state(server).socket
    {fake_socket, peer} = tcp_pair()

    full_queue =
      Enum.reduce(1..64, :queue.new(), fn _index, queue ->
        :queue.in({:all_clients, 0}, queue)
      end)

    :ok = :inet.setopts(original_socket, active: false)

    :sys.replace_state(server, fn state ->
      state
      |> disable_query_owner_for_test()
      |> Map.merge(%{socket: fake_socket, pending_repaints: full_queue})
    end)

    try do
      Server.claim_size(session.id, self(), "queue-test", "queue-device", 25, 81)
      Server.claim_size(session.id, self(), "queue-test", "queue-device", 26, 82)
      _ = Server.size_info(session.id)

      # Query-owner negotiation is disabled above; only the two resize frames
      # belong to this test, so the holder FIFO can be asserted directly.
      frames = recv_packets(peer, 2)
      assert Enum.count(frames, &(&1 == <<0x12, 25::16, 81::16>>)) == 1
      assert Enum.count(frames, &(&1 == <<0x12, 26::16, 82::16>>)) == 1
      assert {:error, :timeout} = :gen_tcp.recv(peer, 0, 100)

      saturated = :sys.get_state(server)
      assert :queue.len(saturated.pending_repaints) == 64
      assert Map.get(saturated, :deferred_all_client_repaint) == true

      # Completing any older request opens one FIFO slot. The latest resize
      # needs exactly one coalesced all-client repaint in that slot.
      send(server, {:tcp, fake_socket, <<Holder.type_repaint(), "OLD">>})
      _ = Server.size_info(session.id)

      history_budget = Holder.repaint_history_budget()
      assert {:ok, <<0x14, 82::16, ^history_budget::32>>} = :gen_tcp.recv(peer, 0, 1_000)
      assert {:error, :timeout} = :gen_tcp.recv(peer, 0, 100)

      repaired = :sys.get_state(server)
      assert :queue.len(repaired.pending_repaints) == 64

      assert List.last(:queue.to_list(repaired.pending_repaints)) ==
               {:all_clients, history_budget}

      refute Map.get(repaired, :deferred_all_client_repaint)
    after
      if Process.alive?(server) do
        :sys.replace_state(server, fn state ->
          state
          |> Map.merge(%{socket: original_socket, pending_repaints: :queue.new()})
          |> Map.put(:deferred_all_client_repaint, false)
        end)

        :ok = :inet.setopts(original_socket, active: true)
      end

      :gen_tcp.close(fake_socket)
      :gen_tcp.close(peer)
    end
  end

  test "the 65th concurrent text snapshot is rejected before the holder socket" do
    session = create_session!()
    server = Server.whereis(session.id)
    original_socket = :sys.get_state(server).socket
    {fake_socket, peer} = tcp_pair()

    :ok = :inet.setopts(original_socket, active: false)

    :sys.replace_state(server, fn state ->
      %{state | socket: fake_socket, pending_text_snapshots: :queue.new()}
    end)

    tasks =
      for _index <- 1..65 do
        Task.async(fn -> Server.snapshot(session.id, lines: 1) end)
      end

    try do
      eventually(fn -> :queue.len(:sys.get_state(server).pending_text_snapshots) >= 64 end)

      completed =
        tasks
        |> Task.yield_many(1_000)
        |> Enum.flat_map(fn
          {_task, {:ok, result}} -> [result]
          {_task, nil} -> []
        end)

      assert completed == [{:error, "too many pending terminal snapshot requests"}]
      assert :queue.len(:sys.get_state(server).pending_text_snapshots) == 64
      assert Process.alive?(server)

      max_bytes = 64 * 1024

      for _index <- 1..64 do
        assert {:ok, <<0x15, 1::32, ^max_bytes::32>>} = :gen_tcp.recv(peer, 0, 1_000)
      end

      assert {:error, :timeout} = :gen_tcp.recv(peer, 0, 100)
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

      if Process.alive?(server) do
        :sys.replace_state(server, fn state ->
          %{state | socket: original_socket, pending_text_snapshots: :queue.new()}
        end)

        :ok = :inet.setopts(original_socket, active: true)
      end

      :gen_tcp.close(fake_socket)
      :gen_tcp.close(peer)
    end
  end

  test "default names come from cwd and receive a readable duplicate suffix" do
    dir = Path.join(System.tmp_dir!(), "dala-name-project")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    first = create_session!(%{cwd: dir})
    second = create_session!(%{cwd: dir})

    assert first.name == "dala-name-project"
    assert second.name == "dala-name-project 2"
  end

  test "create with cwd spawns the shell in that directory (quick shell)" do
    dir = Path.join(System.tmp_dir!(), "dala-quick-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    session = create_session!(%{cwd: dir})
    assert session.cwd == dir

    Server.input(session.id, cwd_marker_command())

    eventually(fn ->
      repaint = repaint_text(session.id) |> String.replace("\\", "/") |> String.downcase()
      expected = "marker-#{dir}" |> String.replace("\\", "/") |> String.downcase()
      String.contains?(repaint, expected)
    end)
  end

  test "cwd follows the focused pane inside zellij" do
    if System.find_executable("zellij") do
      session = create_session!()
      mux = "dala-test-mux-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        System.cmd("zellij", ["kill-session", mux], stderr_to_stdout: true)
        System.cmd("zellij", ["delete-session", mux, "--force"], stderr_to_stdout: true)
      end)

      Server.set_visibility(session.id, self(), "session-test", true)
      Server.input(session.id, "zellij attach --create #{mux}\r")
      Process.sleep(500)
      Dala.Terminal.ProcessSnapshot.refresh()

      # zellij takes a moment to come up; keep issuing cd until the poll
      # (2s cadence) reports the inner pane's directory.
      eventually(
        fn ->
          Server.input(session.id, "cd /tmp\r")
          Process.sleep(400)
          Dala.Terminal.get_session!(session.id).cwd == "/tmp"
        end,
        50
      )
    end
  end

  test "OSC 777 agent events reach the sessions topic" do
    session = create_session!()
    Phoenix.PubSub.subscribe(Dala.PubSub, "sessions")

    json = ~s({"agent":"claude","event":"stop","summary":"done!"})
    assert {:ok, _seq} = raw_output(session.id, "\e]777;notify;warp://cli-agent;#{json}\a")

    assert_receive %Phoenix.Socket.Broadcast{event: "agent_event", payload: payload}, 5_000
    assert payload.agent == "claude"
    assert payload.event == "stop"
    assert payload.summary == "done!"
    assert payload.id == to_string(session.id)
  end

  test "foreground_app reports the process owning the tty" do
    session = create_session!()
    eventually(fn -> match?({:ok, %{app: "shell"}}, Server.foreground_app(session.id)) end)

    command =
      if windows?(),
        do: "powershell.exe -NoProfile -Command \"Start-Sleep -Seconds 5\"",
        else: "sleep 5"

    assert {:ok, _seq} = Server.send_sequence(session.id, [{command, 50}, {"\r", 0}])

    eventually(fn ->
      case Server.foreground_app(session.id) do
        {:ok, %{cmdline: cmdline}} ->
          String.contains?(cmdline, if(windows?(), do: "Start-Sleep", else: "sleep 5"))

        _ ->
          false
      end
    end)
  end

  test "kick_viewers on a plain shell reports no multiplexer" do
    session = create_session!()
    eventually(fn -> match?({:error, _}, Dala.Terminal.Server.kick_viewers(session.id)) end)
    assert {:error, message} = Dala.Terminal.Server.kick_viewers(session.id)
    assert message =~ ~r/no zellij|not running|unavailable/
  end

  test "ephemeral session destroys itself when the shell exits" do
    session = create_session!(%{ephemeral: true})
    assert session.ephemeral

    Phoenix.PubSub.subscribe(Dala.PubSub, "sessions")
    Server.input(session.id, "exit\r")
    await_exit(session.id)

    # the record self-destructs (broadcasting session_deleted) …
    eventually(fn -> match?({:error, _}, Dala.Terminal.get_session(session.id)) end)
    assert_receive %Phoenix.Socket.Broadcast{event: "session_deleted"}, 5_000

    # … and leaves no holder files behind
    id = to_string(session.id)

    eventually(fn ->
      Enum.all?(
        [Holder.exit_path(id), Holder.final_path(id), Holder.text_final_path(id)],
        &(not File.exists?(&1))
      )
    end)
  end

  test "input reaches the shell; output is broadcast and lands in the repaint" do
    session = create_session!()
    Phoenix.PubSub.subscribe(Dala.PubSub, "terminal:#{session.id}")

    Server.input(session.id, arithmetic_command())

    assert_receive %Phoenix.Socket.Broadcast{event: "output"}, 5_000
    eventually(fn -> repaint_text(session.id) =~ if(windows?(), do: "42", else: "dala-42") end)
  end

  test "plain-text snapshot joins wrapped rows and excludes ANSI" do
    session = create_session!()
    marker = String.duplicate("snapshot-text-", 12)
    assert {:ok, _seq} = raw_output(session.id, "\e[31m#{marker}\e[0m\n")

    eventually(fn ->
      case Server.snapshot(session.id, lines: 20) do
        {:ok, snapshot} ->
          output = Enum.join(snapshot["lines"], "\n")
          String.contains?(output, marker) and not String.contains?(output, "\e[")

        _ ->
          false
      end
    end)

    assert {:ok, snapshot} = Server.snapshot(session.id, lines: 20)
    assert snapshot["mode"] == "normal"
    assert is_integer(snapshot["seq"])
    assert snapshot["cachedLineCount"] >= length(snapshot["lines"])
  end

  test "wait wakes on output after the atomic baseline" do
    session = create_session!()
    assert {:ok, baseline} = Server.current_seq(session.id)

    waiter = Task.async(fn -> Server.wait(session.id, baseline, timeout: 3_000) end)
    Process.sleep(50)
    Server.input(session.id, "echo wait-output-marker\r")

    assert {:ok, %{reason: "output", seq: seq}} = Task.await(waiter, 4_000)
    assert seq > baseline
  end

  test "wait can match plain text without polling the holder per output chunk" do
    session = create_session!()
    assert {:ok, baseline} = Server.current_seq(session.id)

    waiter =
      Task.async(fn ->
        Server.wait(session.id, baseline, timeout: 4_000, match: "needle-4242")
      end)

    assert {:ok, _seq} = raw_output(session.id, "\e[32mneedle-4242\e[0m\n")

    assert {:ok, %{reason: "match", match: "needle-4242", seq: seq}} =
             Task.await(waiter, 5_000)

    assert seq > baseline
  end

  test "wait wakes on a selected structured agent event" do
    session = create_session!()
    assert {:ok, baseline} = Server.current_seq(session.id)

    waiter =
      Task.async(fn ->
        Server.wait(session.id, baseline, timeout: 4_000, events: ["permission"])
      end)

    json = ~s({"agent":"claude","event":"permission_request","summary":"approve edit"})

    assert {:ok, _seq} =
             raw_output(session.id, "\e]777;notify;warp://cli-agent;#{json}\a")

    assert {:ok,
            %{
              reason: "agent",
              event: "permission_request",
              agent: "claude",
              summary: "approve edit",
              seq: seq
            }} = Task.await(waiter, 5_000)

    assert seq > baseline
  end

  test "queued rich-input jobs never interleave between callers" do
    session = create_session!()
    path = Path.join(System.tmp_dir!(), "dala-input-queue-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    {first, second} = queue_commands(path)

    assert {:ok, _baseline} = Server.send_sequence(session.id, first)
    assert {:ok, _baseline} = Server.send_sequence(session.id, second)

    eventually(fn -> File.read(path) == {:ok, "ABC"} end)
  end

  test "repaint restores modes a TUI enabled" do
    session = create_session!()
    assert {:ok, baseline} = Server.current_seq(session.id)

    {modes, expected} =
      if windows?(),
        do: {"\e[?1049h\e[?1h", []},
        else: {"\e[?1002h\e[?1006h", ["\e[?1002h", "\e[?1006h"]}

    assert {:ok, _seq} = raw_output(session.id, modes <> "MODE_ACTIVE", 30_000)

    waited = Server.wait(session.id, baseline, timeout: 8_000, match: "MODE_ACTIVE")

    assert match?({:ok, %{reason: "match"}}, waited),
           "fixture did not render: wait=#{inspect(waited)} repaint=#{inspect(repaint_text(session.id))}"

    if windows?() do
      # Windows Server ConPTY may consume private modes while preserving the
      # resulting screen. Native emulator tests cover exact mode restoration.
      eventually(fn -> String.contains?(repaint_text(session.id), "MODE_ACTIVE") end)
    else
      eventually(
        fn ->
          repaint = repaint_text(session.id)
          Enum.all?(expected, &String.contains?(repaint, &1))
        end,
        100
      )
    end
  end

  test "OSC 7 in the output stream updates the session cwd" do
    session = create_session!()

    target = System.tmp_dir!()

    # What a shell integration (or zellij passing it through) emits on chpwd.
    if windows?() do
      assert {:ok, _seq} =
               Server.send_sequence(session.id, [{"cd /d \"#{target}\"", 50}, {"\r", 0}])
    else
      assert {:ok, _seq} = raw_output(session.id, "\e]7;file://localhost#{target}\a")
    end

    eventually(fn ->
      Dala.TestPlatform.same_path?(Dala.Terminal.get_session!(session.id).cwd, target)
    end)
  end

  test "close kills the shell and marks the session exited" do
    session = create_session!()

    assert {:ok, true} =
             Ash.run_action(
               Ash.ActionInput.for_action(Dala.Terminal.Session, :close, %{id: session.id})
             )

    await_exit(session.id)

    reloaded = Dala.Terminal.get_session!(session.id)
    assert reloaded.status == :exited
    refute Server.alive?(session.id)
  end

  test "shell exit broadcasts a mode reset and leaves a final screen file" do
    session = create_session!()
    Phoenix.PubSub.subscribe(Dala.PubSub, "terminal:#{session.id}")

    Server.input(session.id, "echo last-words\r")
    eventually(fn -> repaint_text(session.id) =~ "last-words" end)

    Server.stop(session.id)
    await_exit(session.id)

    # Connected clients must drop stale mouse/paste modes.
    assert_received_mode_reset()

    # And a disconnected client opening the session later sees the last screen.
    assert Holder.read_final(to_string(session.id)) =~ "last-words"
    assert {:ok, final_snapshot} = Holder.read_final_text(to_string(session.id))
    assert Enum.join(final_snapshot["lines"], "\n") =~ "last-words"
  end

  defp assert_received_mode_reset do
    receive do
      %Phoenix.Socket.Broadcast{event: "output", payload: %{data: data}} ->
        if Base.decode64!(data) =~ "\e[?1000l", do: :ok, else: assert_received_mode_reset()
    after
      5_000 -> flunk("mode reset was never broadcast")
    end
  end

  test "restart revives an exited session with a fresh screen" do
    session = create_session!()
    Server.input(session.id, "echo before-restart\r")
    eventually(fn -> repaint_text(session.id) =~ "before-restart" end)

    Server.stop(session.id)
    await_exit(session.id)

    assert {:ok, true} =
             Ash.run_action(
               Ash.ActionInput.for_action(Dala.Terminal.Session, :restart, %{id: session.id})
             )

    assert Server.alive?(session.id)
    eventually(fn -> Dala.Terminal.get_session!(session.id).status == :running end)

    # A fresh shell means a fresh emulator: no stale final screen shadows it.
    assert Holder.read_final(to_string(session.id)) == ""
  end

  test "destroy stops the server and removes holder leftovers" do
    session = create_session!()
    Server.input(session.id, "echo gone\r")
    eventually(fn -> repaint_text(session.id) =~ "gone" end)

    pid = Server.whereis(session.id)
    ref = Process.monitor(pid)
    :ok = Dala.Terminal.delete_session!(session)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 8_000

    assert Holder.read_final(to_string(session.id)) == ""
    refute File.exists?(Holder.exit_path(to_string(session.id)))
    assert {:error, _not_found} = Dala.Terminal.get_session(session.id)
  end

  describe "history_lines/1" do
    test "table: line limits, legacy byte limits and fallbacks" do
      cases = [
        # {stored scrollback_limit, emulator history lines}
        # plain line limits clamp to 1_000..50_000
        {5_000, 5_000},
        {100_000, 50_000},
        {1_000, 1_000},
        {500, 1_000},
        # legacy byte limits (> 100k) convert at ~120 bytes/line, then clamp
        {120_000, 1_000},
        {300_000, 2_500},
        {12_000_000, 50_000},
        {268_435_456, 50_000},
        # everything else falls back to the default
        {0, 10_000},
        {-1, 10_000},
        {nil, 10_000},
        {"junk", 10_000}
      ]

      for {limit, expected} <- cases do
        assert Dala.Terminal.Session.history_lines(limit) == expected,
               "history_lines(#{inspect(limit)}) expected #{expected}"
      end
    end
  end
end
