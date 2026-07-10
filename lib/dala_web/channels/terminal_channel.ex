defmodule DalaWeb.TerminalChannel do
  @moduledoc """
  Per-session terminal channel.

  On join, the client receives a synthesized repaint (history tail + current
  screen + terminal modes) rendered by the session's holder-side emulator —
  the tmux attach model — as `replay` events. For sessions that are no longer
  running, the holder's final screen file is served instead. Live output
  arrives as `output` broadcasts from `Dala.Terminal.Server`; overlap with
  the repaint is deduplicated client-side via `seq`.
  """

  use Phoenix.Channel
  use AshTypescript.TypedChannel

  alias Dala.Terminal.Holder

  # Keep pushed frames comfortably small; base64 inflates by 4/3.
  @replay_batch_bytes 192 * 1024
  @max_rows 500
  @max_cols 1000

  typed_channel do
    topic "terminal:*"

    resource Dala.Terminal.Session do
      publish :output
      publish :replay
      publish :exit
      publish :cwd
    end
  end

  @impl true
  def join("terminal:" <> session_id, _payload, socket) do
    case Dala.Terminal.get_session(session_id) do
      {:ok, session} ->
        session = reconcile_status(session)
        send(self(), :after_join)

        {rows, cols} = Dala.Terminal.Server.viewport(session_id) || {24, 80}

        {:ok, %{status: session.status, cwd: session.cwd, rows: rows, cols: cols},
         assign(socket, :session_id, session.id)}

      {:error, _error} ->
        {:error, %{reason: "not_found"}}
    end
  end

  # A brutally-killed Terminal.Server (code-reload purge, VM crash mid-callback)
  # never runs terminate/2, so its session stays "running" with no process
  # behind it — the UI then shows a dead terminal with no restart overlay and
  # "kill" is a no-op. Reconcile on join, like Dala.Terminal.Boot does at
  # startup: reattach when the detached holder still runs the shell, mark the
  # session exited otherwise so the restart path works again.
  defp reconcile_status(%{status: :running} = session) do
    id = to_string(session.id)

    cond do
      Dala.Terminal.Server.alive?(id) ->
        session

      Dala.Terminal.Holder.exists?(id) ->
        _ = Dala.Terminal.Server.ensure_started(session)
        session

      true ->
        exit_code = Dala.Terminal.Holder.take_exit_status(id)

        case Dala.Terminal.mark_exited(session, %{exit_code: exit_code}) do
          {:ok, reconciled} -> reconciled
          {:error, _error} -> session
        end
    end
  end

  defp reconcile_status(session), do: session

  @impl true
  def handle_info(:after_join, socket) do
    id = socket.assigns.session_id

    if Dala.Terminal.Server.alive?(id) do
      # The repaint is deferred until the client's `attach` reports its true
      # viewport — sizing first lets the emulator reflow, so soft wraps match
      # the client's width. The timer covers clients that never attach.
      Process.send_after(self(), :repaint_timeout, 4_000)
      {:noreply, assign(socket, :replayed, false)}
    else
      # Not running: serve the final screen the holder left behind.
      {:noreply, push_replay(socket, Holder.read_final(id), 0)}
    end
  end

  def handle_info({:repaint, data, seq}, socket) do
    if socket.assigns[:replayed] do
      {:noreply, socket}
    else
      {:noreply, push_replay(socket, data, seq)}
    end
  end

  def handle_info(:repaint_timeout, socket) do
    if socket.assigns[:replayed] do
      {:noreply, socket}
    else
      {:noreply, push_replay(socket, "", 0)}
    end
  end

  @impl true
  def handle_in("attach", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    id = socket.assigns.session_id
    rows = min(max(rows, 1), @max_rows)
    cols = min(max(cols, 1), @max_cols)

    # Order matters: the resize reaches the holder (reflow) before the
    # repaint request on the same FIFO socket.
    Dala.Terminal.Server.resize(id, self(), rows, cols)

    if Dala.Terminal.Server.alive?(id) and not socket.assigns[:replayed] and
         not Map.get(socket.assigns, :repaint_requested, false) do
      Dala.Terminal.Server.request_repaint(id, self())
    end

    {:noreply, assign(socket, :repaint_requested, true)}
  end

  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    Dala.Terminal.Server.input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    rows = min(max(rows, 1), @max_rows)
    cols = min(max(cols, 1), @max_cols)
    # `self()` is this channel process — one per connected client. The server
    # tracks each client's size and sizes the shared PTY to their minimum.
    Dala.Terminal.Server.resize(socket.assigns.session_id, self(), rows, cols)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # Pushes one repaint as a series of replay batches. Every batch carries the
  # repaint's seq watermark; the last one is flagged `done` so the client can
  # uncover and re-enable input.
  defp push_replay(socket, data, seq) do
    chunks = chunk_binary(data, @replay_batch_bytes)

    chunks
    |> Enum.with_index(1)
    |> Enum.each(fn {chunk, index} ->
      push(socket, "replay", %{
        data: Base.encode64(chunk),
        seq: seq,
        done: index == length(chunks)
      })
    end)

    assign(socket, :replayed, true)
  end

  defp chunk_binary("", _size), do: [""]

  defp chunk_binary(data, size) when byte_size(data) <= size, do: [data]

  defp chunk_binary(data, size) do
    <<head::binary-size(size), rest::binary>> = data
    [head | chunk_binary(rest, size)]
  end
end
