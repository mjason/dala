defmodule DalaWeb.FileWatchSocket do
  @moduledoc """
  Pushes directory-change notifications to the file drawer.

  The client sends `{"watch": ["/abs/dir", …], "root": "/abs"}` whenever its
  set of expanded directories (or its root) changes; the server answers with
  `{"changed": "/abs/dir"}` frames naming directories whose listings went
  stale. Backend: the `dala_holder watch` subcommand — the PTY holder binary
  built at compile time — covering the whole tree under the root with one
  non-recursive watch per directory (inotify on Linux, FSEvents on macOS),
  heavy machine-generated trees skipped at registration so they consume no
  watch descriptors. Changes anywhere under the root are seen, not just in
  expanded dirs, and the client routes each to the nearest visible ancestor.

  Orphan-proofing: the watcher exits on stdin EOF, which the OS delivers the
  moment this socket's port closes — including when the BEAM is SIGKILLed.
  No teardown message can be missed, so no watcher can outlive dala.

  Fallback when the binary is missing (or dies): directory-mtime polling of
  the expanded dirs — POSIX bumps a dir's mtime on create/delete/rename,
  which is exactly what the tree displays. The watcher also *asks* for that
  degradation with sentinel stdout lines: `!fallback <reason>` (pathological
  root — `/`, `$HOME`, or one whose walk blows the dir budget) and
  `!error <reason>` (fatal watch failure, followed by exit(1)).
  """

  @behaviour WebSock

  require Logger

  @poll_ms 800
  # The watcher already coalesces for ~200ms; this only merges cross-batch
  # arrivals into fewer frames.
  @debounce_ms 100
  @max_dirs 200

  @impl true
  def init(_params) do
    backend = if watcher_binary(), do: :native, else: :poll
    if backend == :poll, do: Process.send_after(self(), :poll, @poll_ms)

    {:ok,
     %{
       backend: backend,
       dirs: %{},
       root: nil,
       port: nil,
       pending: MapSet.new(),
       flush: nil,
       buffer: ""
     }}
  end

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    case Jason.decode(message) do
      {:ok, %{"watch" => dirs} = payload} when is_list(dirs) ->
        dirs =
          dirs
          |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
          |> Enum.map(&normalize_host_path/1)
          |> Enum.take(@max_dirs)

        {:ok, state |> set_dirs(dirs) |> set_root(watch_root(payload, dirs))}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:ok, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    state = %{state | buffer: ""}

    case line do
      # Sentinels: the watcher itself asks for degradation (`!fallback` for
      # pathological roots / dir-budget blowouts, `!error` just before a
      # fatal exit). Either way: poll instead.
      "!" <> _ ->
        {:ok, degrade_to_poll(state, "watcher reported #{inspect(line)}")}

      _ ->
        dir = normalize_host_path(line)
        {:ok, schedule_flush(%{state | pending: MapSet.put(state.pending, dir)})}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # The watcher died underneath us (crash, kill, OOM). Degrade to mtime
    # polling of the expanded dirs rather than respawn-looping.
    {:ok, degrade_to_poll(state, "watcher exited with status #{status}")}
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

  # The recursive watch root: what the client names, or (for old payloads
  # naming only expanded dirs) the shallowest of them — the tree root is
  # always in the expanded set.
  defp watch_root(%{"root" => root}, _dirs) when is_binary(root) do
    if File.dir?(root), do: normalize_host_path(root)
  end

  defp watch_root(_payload, []), do: nil
  defp watch_root(_payload, dirs), do: Enum.min_by(dirs, &byte_size/1)

  defp set_dirs(state, dirs) do
    case state.backend do
      # Kept for parity with what the client shows; becomes the poll set if
      # the watcher ever dies.
      :native -> %{state | dirs: Map.new(dirs, &{&1, nil})}
      :poll -> %{state | dirs: poll_baseline(Map.new(dirs, &{&1, nil}))}
    end
  end

  defp set_root(%{backend: :native} = state, nil) do
    Dala.ShellPort.close(state.port)
    %{state | root: nil, port: nil}
  end

  defp set_root(%{backend: :native, root: root} = state, root), do: state

  defp set_root(%{backend: :native} = state, root) do
    port = state.port || open_watcher()

    # The port can die between its exit_status landing in our mailbox and
    # this send (Port.command on a dead port raises) — degrade right away,
    # exactly what the queued exit_status would have done.
    try do
      Port.command(port, root <> "\n")
      %{state | root: root, port: port}
    rescue
      ArgumentError ->
        degrade_to_poll(%{state | port: port}, "watcher port dead on set_root")
    end
  end

  defp set_root(state, _root), do: state

  # The shared degradation path: drop the native watcher, become a polling
  # socket for the currently-watched dirs.
  defp degrade_to_poll(state, reason) do
    Logger.warning("file watcher: #{reason}; degrading to mtime polling")
    Dala.ShellPort.close(state.port)
    Process.send_after(self(), :poll, @poll_ms)
    %{state | backend: :poll, port: nil, root: nil, dirs: poll_baseline(state.dirs)}
  end

  defp poll_baseline(dirs) do
    Map.new(dirs, fn {dir, _} ->
      case File.stat(dir, time: :posix) do
        {:ok, %{mtime: mtime}} -> {dir, mtime}
        _ -> {dir, nil}
      end
    end)
  end

  defp open_watcher do
    # Through the shell wrapper for the stderr redirect (a port child
    # inherits the BEAM's stderr; see Dala.ShellPort). `exec` keeps the
    # watcher itself as the port's os_pid, and its stdin is the port pipe —
    # the EOF tether. Line mode: the protocol is one directory per line.
    Dala.ShellPort.open([watcher_binary(), "watch"], "/dev/null", [{:line, 4096}])
  end

  defp watcher_binary do
    executable = if match?({:win32, _}, :os.type()), do: "dala_holder.exe", else: "dala_holder"
    path = Path.join([:code.priv_dir(:dala), "bin", executable])
    if File.exists?(path), do: path
  end

  defp normalize_host_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> case do
      <<letter, ?:>> = drive when letter in ?A..?Z or letter in ?a..?z -> drive <> "/"
      "" -> "/"
      normalized -> normalized
    end
  end

  defp schedule_flush(%{flush: nil} = state),
    do: %{state | flush: Process.send_after(self(), :flush, @debounce_ms)}

  defp schedule_flush(state), do: state
end
