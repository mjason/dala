defmodule DalaWeb.FileWatchSocketTest do
  use ExUnit.Case, async: true

  alias DalaWeb.FileWatchSocket

  setup do
    dir = Path.join(System.tmp_dir!(), "watch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  defp drain_until_changed(state, dir, deadline_ms) do
    receive do
      message ->
        case FileWatchSocket.handle_info(message, state) do
          {:push, frames, state} ->
            if Enum.any?(frames, fn {:text, body} ->
                 Jason.decode!(body)["changed"] == dir
               end),
               do: :ok,
               else: drain_until_changed(state, dir, deadline_ms)

          {:ok, state} ->
            drain_until_changed(state, dir, deadline_ms)
        end
    after
      deadline_ms -> :timeout
    end
  end

  test "inotify backend pushes changed after a file appears", %{dir: dir} do
    {:ok, state} = FileWatchSocket.init(%{})
    assert state.backend == :inotify

    {:ok, state} =
      FileWatchSocket.handle_in({Jason.encode!(%{watch: [dir]}), [opcode: :text]}, state)

    on_exit(fn -> FileWatchSocket.terminate(:normal, state) end)

    # inotifywait needs a beat to establish watches; keep writing until the
    # event lands instead of racing it once.
    writer =
      Task.async(fn ->
        for n <- 1..20 do
          File.write!(Path.join(dir, "hello-#{n}.txt"), "hi")
          Process.sleep(150)
        end
      end)

    assert drain_until_changed(state, dir, 5_000) == :ok
    Task.shutdown(writer, :brutal_kill)
  end

  test "poll backend detects dir mtime changes", %{dir: dir} do
    # Force the poll path by driving its handlers directly.
    state = %{backend: :poll, dirs: %{}, port: nil, pending: MapSet.new(), flush: nil}

    {:ok, state} =
      FileWatchSocket.handle_in({Jason.encode!(%{watch: [dir]}), [opcode: :text]}, state)

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

  test "nonexistent dirs are ignored", %{dir: dir} do
    {:ok, state} = FileWatchSocket.init(%{})

    {:ok, state} =
      FileWatchSocket.handle_in(
        {Jason.encode!(%{watch: [Path.join(dir, "nope"), 42]}), [opcode: :text]},
        state
      )

    assert state.dirs == %{}
    FileWatchSocket.terminate(:normal, state)
  end
end
