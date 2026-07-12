defmodule DalaWeb.FileWatchSocket do
  @moduledoc """
  Pushes directory-change notifications to the file drawer.

  The client sends `{"watch": ["/abs/dir", …]}` whenever its set of expanded
  directories changes; the server answers with `{"changed": "/abs/dir"}` as
  soon as entries appear/disappear there. Backend: `inotifywait` when the
  host has it (real events, immediate), otherwise directory-mtime polling —
  POSIX bumps a dir's mtime on create/delete/rename, which is exactly what
  the tree displays.
  """

  @behaviour WebSock

  require Logger

  @poll_ms 800
  # inotify events flood on bulk operations (npm install…) — coalesce.
  @debounce_ms 250
  @max_dirs 200

  @impl true
  def init(_params) do
    backend = if System.find_executable("inotifywait"), do: :inotify, else: :poll
    if backend == :poll, do: Process.send_after(self(), :poll, @poll_ms)
    {:ok, %{backend: backend, dirs: %{}, port: nil, pending: MapSet.new(), flush: nil}}
  end

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    case Jason.decode(message) do
      {:ok, %{"watch" => dirs}} when is_list(dirs) ->
        dirs =
          dirs
          |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
          |> Enum.take(@max_dirs)

        {:ok, set_dirs(state, dirs)}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    # inotifywait --format %w prints the watched directory, one per line.
    changed =
      chunk
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_trailing(&1, "/"))
      |> Enum.filter(&Map.has_key?(state.dirs, &1))

    {:ok, schedule_flush(%{state | pending: Enum.into(changed, state.pending)})}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    # inotifywait died (e.g. a watched dir was deleted) — restart with the
    # still-existing dirs.
    {:ok, set_dirs(%{state | port: nil}, state.dirs |> Map.keys() |> Enum.filter(&File.dir?/1))}
  end

  def handle_info(:flush, state) do
    frames = for dir <- state.pending, do: {:text, Jason.encode!(%{changed: dir})}
    state = %{state | pending: MapSet.new(), flush: nil}

    case frames do
      [] -> {:ok, state}
      _ -> {:push, frames, state}
    end
  end

  def handle_info(:poll, %{backend: :poll} = state) do
    {dirs, changed} =
      Enum.map_reduce(state.dirs, [], fn {dir, last_mtime}, acc ->
        case File.stat(dir, time: :posix) do
          {:ok, %{mtime: mtime}} when mtime != last_mtime -> {{dir, mtime}, [dir | acc]}
          {:ok, %{mtime: mtime}} -> {{dir, mtime}, acc}
          # deleted dir: report once so the parent view can react, then keep
          # polling — it may reappear.
          {:error, _} -> {{dir, nil}, if(last_mtime, do: [dir | acc], else: acc)}
        end
      end)

    Process.send_after(self(), :poll, @poll_ms)
    state = %{state | dirs: Map.new(dirs), pending: Enum.into(changed, state.pending)}
    {:ok, if(changed == [], do: state, else: schedule_flush(state))}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    Dala.ShellPort.close(state.port)
    :ok
  end

  defp set_dirs(state, dirs) do
    case state.backend do
      :inotify ->
        Dala.ShellPort.close(state.port)
        port = if dirs == [], do: nil, else: open_inotify(dirs)
        %{state | dirs: Map.new(dirs, &{&1, nil}), port: port}

      :poll ->
        mtimes =
          Map.new(dirs, fn dir ->
            case File.stat(dir, time: :posix) do
              {:ok, %{mtime: mtime}} -> {dir, mtime}
              _ -> {dir, nil}
            end
          end)

        %{state | dirs: mtimes}
    end
  end

  defp open_inotify(dirs) do
    events =
      Enum.flat_map(["create", "delete", "moved_to", "moved_from", "close_write"], fn e ->
        ["--event", e]
      end)

    args = ["--monitor", "--quiet", "--format", "%w"] ++ events ++ dirs

    # Through the shell wrapper so a lingering inotifywait can't hold the
    # beam's stderr fd open (see Dala.ShellPort).
    Dala.ShellPort.open([System.find_executable("inotifywait") | args], "/dev/null")
  end

  defp schedule_flush(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @debounce_ms)}

  defp schedule_flush(state), do: state
end
