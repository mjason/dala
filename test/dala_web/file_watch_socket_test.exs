defmodule DalaWeb.FileWatchSocketTest do
  use ExUnit.Case, async: true

  alias DalaWeb.FileWatchSocket

  setup do
    dir =
      Dala.TestPlatform.normalize_path(
        Path.join(System.tmp_dir!(), "watch-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  defp watch!(state, dirs, root \\ nil) do
    payload = if root, do: %{watch: dirs, root: root}, else: %{watch: dirs}
    {:ok, state} = FileWatchSocket.handle_in({Jason.encode!(payload), [opcode: :text]}, state)
    state
  end

  # Feeds mailbox messages through the socket's handle_info until a push for
  # `dir` arrives (returns all pushed dirs seen), or the deadline passes.
  defp drain_until_changed(state, dir, deadline_ms, seen \\ []) do
    receive do
      message ->
        case FileWatchSocket.handle_info(message, state) do
          {:push, frames, state} ->
            pushed = Enum.map(frames, fn {:text, body} -> Jason.decode!(body)["changed"] end)
            seen = seen ++ pushed

            if dir in pushed,
              do: {:ok, seen},
              else: drain_until_changed(state, dir, deadline_ms, seen)

          {:ok, state} ->
            drain_until_changed(state, dir, deadline_ms, seen)
        end
    after
      deadline_ms -> {:timeout, seen}
    end
  end

  # Feeds mailbox messages through handle_info until the socket's backend
  # becomes `backend` (degradation is driven by port messages).
  defp drain_until_backend(%{backend: backend} = state, backend, _deadline_ms), do: {:ok, state}

  defp drain_until_backend(state, backend, deadline_ms) do
    receive do
      message ->
        case FileWatchSocket.handle_info(message, state) do
          {:push, _frames, state} -> drain_until_backend(state, backend, deadline_ms)
          {:ok, state} -> drain_until_backend(state, backend, deadline_ms)
        end
    after
      deadline_ms -> {:timeout, state}
    end
  end

  # The recursive watch is established asynchronously; poke the root with
  # marker writes until the first push proves it is live.
  defp await_established(state, dir, attempts \\ 40) do
    marker = Path.join(dir, ".establish-marker")
    File.write!(marker, "x")

    case drain_until_changed(state, dir, 250) do
      {:ok, _seen} ->
        File.rm!(marker)
        :ok

      {:timeout, _seen} when attempts > 1 ->
        await_established(state, dir, attempts - 1)

      {:timeout, _seen} ->
        flunk("watcher never established for #{dir}")
    end
  end

  describe "native backend (dala_holder watch)" do
    test "detects the holder binary", %{dir: _dir} do
      {:ok, state} = FileWatchSocket.init(%{})
      assert state.backend == :native
    end

    test "pushes the containing dir for nested changes under the root", %{dir: dir} do
      nested = Path.join(dir, "sub/deep")
      File.mkdir_p!(nested)

      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      on_exit(fn -> FileWatchSocket.terminate(:normal, state) end)
      await_established(state, dir)

      File.write!(Path.join(nested, "hello.txt"), "hi")
      assert {:ok, _seen} = drain_until_changed(state, nested, 2_000)
    end

    test "derives the root from the watch list when none is sent", %{dir: dir} do
      nested = Path.join(dir, "inner")
      File.mkdir_p!(nested)

      {:ok, state} = FileWatchSocket.init(%{})
      # Old-style payload: expanded dirs only. Shortest dir is the root.
      state = watch!(state, [nested, dir])
      on_exit(fn -> FileWatchSocket.terminate(:normal, state) end)
      await_established(state, dir)

      File.write!(Path.join(nested, "n.txt"), "x")
      assert {:ok, _seen} = drain_until_changed(state, nested, 2_000)
    end

    test "excluded trees stay silent", %{dir: dir} do
      nm = Path.join(dir, "node_modules/pkg")
      File.mkdir_p!(nm)

      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      on_exit(fn -> FileWatchSocket.terminate(:normal, state) end)
      await_established(state, dir)

      File.write!(Path.join(nm, "junk.js"), "x")
      # Control write after the excluded one; when its push arrives, the
      # excluded push (if any) would already have been seen.
      File.write!(Path.join(dir, "control.txt"), "x")
      assert {:ok, seen} = drain_until_changed(state, dir, 2_000)
      refute Enum.any?(seen, &String.contains?(&1, "node_modules"))
    end

    test "navigating to a new root replaces the watch", %{dir: dir} do
      root_a = Path.join(dir, "a")
      root_b = Path.join(dir, "b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [root_a], root_a)
      on_exit(fn -> FileWatchSocket.terminate(:normal, state) end)
      await_established(state, root_a)

      state = watch!(state, [root_b], root_b)
      await_established(state, root_b)

      File.write!(Path.join(root_a, "stale.txt"), "x")
      File.write!(Path.join(root_b, "fresh.txt"), "x")
      assert {:ok, seen} = drain_until_changed(state, root_b, 2_000)
      refute root_a in seen
    end

    test "an empty watch list tears the watcher down", %{dir: dir} do
      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      assert state.port != nil
      state = watch!(state, [])
      assert state.port == nil
      assert state.root == nil
    end

    # Process liveness is checked through /proc — Linux only (macOS/BSD
    # would need kill -0 semantics instead).
    if match?({:unix, :linux}, :os.type()) do
      test "the watcher OS process dies with a brutally-killed owner", %{dir: dir} do
        parent = self()

        owner =
          spawn(fn ->
            {:ok, state} = FileWatchSocket.init(%{})
            state = watch!(state, [dir], dir)
            {:os_pid, os_pid} = Port.info(state.port, :os_pid)
            send(parent, {:os_pid, os_pid})

            receive do
              :never -> :ok
            end
          end)

        assert_receive {:os_pid, os_pid}, 5_000
        ref = Process.monitor(owner)
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

        # The port closes with its owner; stdin EOF must kill the watcher
        # within ~1s — the orphan-proofing contract.
        assert wait_until(fn -> not File.exists?("/proc/#{os_pid}") end, 1_500),
               "watcher (os pid #{os_pid}) outlived its owner"
      end
    end
  end

  describe "poll fallback" do
    test "watcher notifications preserve leading and trailing spaces in directory names" do
      path = Path.join(System.tmp_dir!(), " leading and trailing ")
      expected = path |> Path.expand() |> String.replace("\\", "/")
      {:ok, state} = FileWatchSocket.init(%{})
      port = make_ref()

      assert {:ok, state} =
               FileWatchSocket.handle_info({port, {:data, {:eol, path}}}, %{state | port: port})

      assert MapSet.member?(state.pending, expected)
      Process.cancel_timer(state.flush)

      assert {:push, [{:text, body}], _state} = FileWatchSocket.handle_info(:flush, state)
      assert Jason.decode!(body)["changed"] == expected
    end

    test "detects dir mtime changes", %{dir: dir} do
      state = poll_state()
      state = watch!(state, [dir])

      # Backdate the recorded mtime so the next poll sees a change without
      # having to sleep across a filesystem-timestamp second boundary.
      state = %{state | dirs: Map.new(state.dirs, fn {d, m} -> {d, m && m - 10} end)}
      File.write!(Path.join(dir, "new.txt"), "x")

      {:ok, state} = FileWatchSocket.handle_info(:poll, state)
      assert MapSet.member?(state.pending, dir)

      assert {:push, frames, _state} = FileWatchSocket.handle_info(:flush, state)
      assert [{:text, body}] = frames
      assert Jason.decode!(body)["changed"] == dir
    end

    test "a dead watcher degrades the socket to polling", %{dir: dir} do
      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      port = state.port

      {:ok, state} = FileWatchSocket.handle_info({port, {:exit_status, 1}}, state)
      assert state.backend == :poll
      assert state.port == nil
      # Poll baselines were (re)established for the watched dirs.
      assert Map.has_key?(state.dirs, dir)
    end

    test "a !fallback sentinel line degrades the socket to polling", %{dir: dir} do
      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      port = state.port

      {:ok, state} =
        FileWatchSocket.handle_info(
          {port, {:data, {:eol, "!fallback dir budget exceeded (30000)"}}},
          state
        )

      assert state.backend == :poll
      assert state.port == nil
      assert Map.has_key?(state.dirs, dir)
    end

    test "an !error sentinel line degrades the socket to polling", %{dir: dir} do
      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [dir], dir)
      port = state.port

      {:ok, state} =
        FileWatchSocket.handle_info({port, {:data, {:eol, "!error /x: watch limit"}}}, state)

      assert state.backend == :poll
      assert state.port == nil
    end

    test "watching $HOME itself degrades to polling (guardrail, end to end)" do
      home = Dala.TestPlatform.normalize_path(System.user_home!())
      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [home], home)

      # The watcher prints `!fallback root is $HOME` instead of walking the
      # tree; feeding mailbox messages through handle_info flips the backend.
      assert {:ok, state} = drain_until_backend(state, :poll, 5_000)
      assert state.port == nil
    end

    test "a root replacing a dead port degrades instead of crashing", %{dir: dir} do
      root_a = Path.join(dir, "a")
      root_b = Path.join(dir, "b")
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)

      {:ok, state} = FileWatchSocket.init(%{})
      state = watch!(state, [root_a], root_a)

      # Kill the OS process AND close the port: the exit_status message may
      # still be in flight when the next watch frame arrives.
      Dala.ShellPort.close(state.port)
      state = watch!(state, [root_b], root_b)
      assert state.backend == :poll
      assert state.port == nil
    end
  end

  test "nonexistent dirs are ignored", %{dir: dir} do
    {:ok, state} = FileWatchSocket.init(%{})
    state = watch!(state, [Path.join(dir, "nope"), 42])
    assert state.dirs == %{}
    assert state.port == nil
    FileWatchSocket.terminate(:normal, state)
  end

  @tag skip: not Dala.TestPlatform.windows?()
  test "normalizes every Windows drive root as an absolute path" do
    drive_root = System.fetch_env!("SystemDrive") <> "\\"
    state = watch!(poll_state(), [drive_root], drive_root)

    assert [normalized] = Map.keys(state.dirs)
    assert normalized =~ ~r/^[a-zA-Z]:\/$/
  end

  defp poll_state do
    %{
      backend: :poll,
      dirs: %{},
      root: nil,
      port: nil,
      pending: MapSet.new(),
      flush: nil,
      buffer: ""
    }
  end

  if match?({:unix, :linux}, :os.type()) do
    defp wait_until(fun, timeout_ms) when timeout_ms > 0 do
      if fun.() do
        true
      else
        receive do
        after
          50 -> :ok
        end

        wait_until(fun, timeout_ms - 50)
      end
    end

    defp wait_until(_fun, _timeout_ms), do: false
  end
end
