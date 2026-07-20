defmodule Dala.Terminal.SessionTest do
  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, attrs))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      File.rm(Holder.exit_path(to_string(session.id)))
      File.rm(Holder.final_path(to_string(session.id)))
      File.rm(Holder.text_final_path(to_string(session.id)))
    end)

    session
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

    Server.input(session.id, "echo marker-$PWD\r")
    eventually(fn -> repaint_text(session.id) =~ "marker-#{dir}" end)
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
    Server.input(session.id, "printf '\\e]777;notify;warp://cli-agent;#{json}\\a'\r")

    assert_receive %Phoenix.Socket.Broadcast{event: "agent_event", payload: payload}, 5_000
    assert payload.agent == "claude"
    assert payload.event == "stop"
    assert payload.summary == "done!"
    assert payload.id == to_string(session.id)
  end

  test "foreground_app reports the process owning the tty" do
    session = create_session!()
    eventually(fn -> match?({:ok, %{app: "shell"}}, Server.foreground_app(session.id)) end)

    Server.input(session.id, "sleep 5\r")
    eventually(fn -> match?({:ok, %{cmdline: "sleep 5"}}, Server.foreground_app(session.id)) end)
  end

  test "kick_viewers on a plain shell reports no multiplexer" do
    session = create_session!()
    eventually(fn -> match?({:error, _}, Dala.Terminal.Server.kick_viewers(session.id)) end)
    assert {:error, message} = Dala.Terminal.Server.kick_viewers(session.id)
    assert message =~ ~r/no zellij|not running/
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
    refute File.exists?(Holder.exit_path(id))
    refute File.exists?(Holder.final_path(id))
  end

  test "input reaches the shell; output is broadcast and lands in the repaint" do
    session = create_session!()
    Phoenix.PubSub.subscribe(Dala.PubSub, "terminal:#{session.id}")

    Server.input(session.id, "echo dala-$((40 + 2))\r")

    assert_receive %Phoenix.Socket.Broadcast{event: "output"}, 5_000
    eventually(fn -> repaint_text(session.id) =~ "dala-42" end)
  end

  test "plain-text snapshot joins wrapped rows and excludes ANSI" do
    session = create_session!()
    marker = String.duplicate("snapshot-text-", 12)
    Server.input(session.id, "printf '\\033[31m#{marker}\\033[0m\\n'\r")

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

    Server.input(session.id, "printf '\\033[32mneedle-4242\\033[0m\\n'\r")

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
    Server.input(session.id, "printf '\\e]777;notify;warp://cli-agent;#{json}\\a'\r")

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

    first = [
      {"printf A > #{path};", 150},
      {"printf B >> #{path}\r", 0}
    ]

    assert {:ok, _baseline} = Server.send_sequence(session.id, first)
    assert {:ok, _baseline} = Server.send_sequence(session.id, [{"printf C >> #{path}\r", 0}])

    eventually(fn -> File.read(path) == {:ok, "ABC"} end)
  end

  test "repaint restores modes a TUI enabled" do
    session = create_session!()

    Server.input(session.id, "printf '\\e[?1002h\\e[?1006h'\r")

    eventually(fn ->
      repaint = repaint_text(session.id)
      repaint =~ "\e[?1002h" and repaint =~ "\e[?1006h"
    end)
  end

  test "OSC 7 in the output stream updates the session cwd" do
    session = create_session!()

    # What a shell integration (or zellij passing it through) emits on chpwd.
    Server.input(session.id, "printf '\\e]7;file://%s/tmp\\a' \"$HOST\"\r")

    eventually(fn -> Dala.Terminal.get_session!(session.id).cwd == "/tmp" end)
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
