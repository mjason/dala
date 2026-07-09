defmodule DalaWeb.TerminalChannel do
  @moduledoc """
  Per-session terminal channel.

  On join, the DETS scrollback is replayed to the client as a series of
  `replay` events (pushed after the join completes, so chunks broadcast in the
  meantime are deduplicated client-side via `seq`). Live output arrives as
  `output` broadcasts from `Dala.Terminal.Server`; keyboard input and resizes
  come in via `input`/`resize`.
  """

  use Phoenix.Channel
  use AshTypescript.TypedChannel

  alias Dala.Terminal.Scrollback

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
    chunks = Scrollback.replay(socket.assigns.session_id)
    push_replay(socket, chunks)
    {:noreply, socket}
  end

  @impl true
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

  defp push_replay(socket, chunks) do
    {batch, batch_bytes, last_seq} =
      Enum.reduce(chunks, {[], 0, -1}, fn {seq, data}, {batch, bytes, _last} ->
        if bytes > 0 and bytes + byte_size(data) > @replay_batch_bytes do
          push_batch(socket, batch, seq - 1, false)
          {[data], byte_size(data), seq}
        else
          {[data | batch], bytes + byte_size(data), seq}
        end
      end)

    _ = batch_bytes
    push_batch(socket, batch, last_seq, true)
  end

  defp push_batch(socket, reversed_batch, last_seq, done) do
    data =
      reversed_batch
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> Base.encode64()

    push(socket, "replay", %{data: data, seq: last_seq, done: done})
  end
end
