defmodule Dala.Terminal.Holder do
  @moduledoc """
  Client for the per-session PTY holder processes (`native/dala_holder`).

  Each terminal's PTY lives in its own tiny daemonized OS process so shells
  survive dala restarts. The holder listens on a unix socket; frames are
  4-byte length prefixed (`packet: 4`) with a 1-byte type tag.
  """

  @type_hello 0x01
  @type_output 0x02
  @type_exit 0x03
  @type_repaint 0x04
  @type_input 0x11
  @type_resize 0x12
  @type_kill 0x13
  @type_repaint_req 0x14

  @connect_attempts 40
  @connect_delay_ms 25

  def type_hello, do: @type_hello
  def type_output, do: @type_output
  def type_exit, do: @type_exit
  def type_repaint, do: @type_repaint

  def dir do
    base = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()
    Path.join(base, "dala-pty")
  end

  def socket_path(id), do: Path.join(dir(), id <> ".sock")
  def exit_path(id), do: socket_path(id) <> ".exit"
  def final_path(id), do: socket_path(id) <> ".final"

  @doc "Whether a holder (a live shell) exists for this session."
  def exists?(id), do: File.exists?(socket_path(id))

  @doc """
  Reads and consumes the exit-status file a holder leaves behind when its
  shell dies while no client is attached.
  """
  def take_exit_status(id) do
    path = exit_path(id)

    case File.read(path) do
      {:ok, contents} ->
        File.rm(path)

        case Integer.parse(String.trim(contents)) do
          {status, _rest} -> status
          :error -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  The final screen a holder rendered when its shell exited — shown when a
  client opens a session that is no longer running. Kept until the session
  is deleted or a fresh shell replaces it.
  """
  def read_final(id) do
    case File.read(final_path(id)) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  @doc """
  Connects to the session's holder, spawning one (a fresh shell) if none is
  alive. Returns `{:ok, socket, reattached?}`.
  """
  def attach_or_spawn(id, opts) do
    case connect(id) do
      {:ok, socket} ->
        {:ok, socket, true}

      {:error, _reason} ->
        # Stale leftovers from a crashed holder must not block the bind, and a
        # stale exit file must not shadow this fresh shell's eventual status.
        _ = File.rm(socket_path(id))
        _ = File.rm(exit_path(id))
        _ = File.rm(final_path(id))

        with :ok <- spawn_holder(id, opts),
             {:ok, socket} <- connect_with_retry(id, @connect_attempts) do
          {:ok, socket, false}
        end
    end
  end

  def connect(id) do
    path = socket_path(id)

    if File.exists?(path) do
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        packet: 4,
        active: true
      ])
    else
      {:error, :enoent}
    end
  end

  def send_input(socket, data), do: :gen_tcp.send(socket, <<@type_input, data::binary>>)

  def send_resize(socket, rows, cols),
    do: :gen_tcp.send(socket, <<@type_resize, rows::16, cols::16>>)

  def send_kill(socket), do: :gen_tcp.send(socket, <<@type_kill>>)

  @doc "Ask the holder for a synthesized full repaint (answered as a REPAINT frame)."
  def send_repaint_req(socket), do: :gen_tcp.send(socket, <<@type_repaint_req>>)

  defp spawn_holder(id, opts) do
    binary = binary_path()

    config =
      Jason.encode!(%{
        socket: socket_path(id),
        shell: Keyword.fetch!(opts, :shell),
        args: Keyword.get(opts, :args, []),
        cwd: Keyword.get(opts, :cwd, ""),
        env: Keyword.get(opts, :env, []) |> Enum.map(&Tuple.to_list/1),
        env_remove: Keyword.get(opts, :env_remove, []),
        rows: Keyword.get(opts, :rows, 24),
        cols: Keyword.get(opts, :cols, 80),
        history_lines: Keyword.get(opts, :history_lines, 10_000)
      })

    File.mkdir_p!(dir())

    # The holder daemonizes (its foreground parent exits immediately), so this
    # returns as soon as the socket is being set up.
    case System.cmd(binary, [config], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:holder_spawn_failed, code, String.trim(out)}}
    end
  end

  defp connect_with_retry(id, attempts) do
    Enum.reduce_while(1..attempts, {:error, :enoent}, fn _n, _acc ->
      case connect(id) do
        {:ok, socket} ->
          {:halt, {:ok, socket}}

        {:error, _reason} = error ->
          Process.sleep(@connect_delay_ms)
          {:cont, error}
      end
    end)
  end

  defp binary_path do
    Path.join(:code.priv_dir(:dala), "bin/dala_holder")
  end
end
