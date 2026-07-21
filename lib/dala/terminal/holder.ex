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
  @type_cwd 0x05
  @type_agent 0x06
  @type_text_snapshot 0x07
  @type_processes 0x08
  @type_auth 0x10
  @type_input 0x11
  @type_resize 0x12
  @type_kill 0x13
  @type_repaint_req 0x14
  @type_text_snapshot_req 0x15
  @repaint_history_budget 512 * 1024
  @type_processes_req 0x16

  @connect_attempts 40
  @connect_delay_ms 25
  @kill_timeout_ms 5_000

  def type_hello, do: @type_hello
  def type_output, do: @type_output
  def type_exit, do: @type_exit
  def type_repaint, do: @type_repaint
  def type_cwd, do: @type_cwd
  def type_agent, do: @type_agent
  def type_text_snapshot, do: @type_text_snapshot
  def type_processes, do: @type_processes

  def dir do
    base = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()
    Path.join(base, "dala-pty")
  end

  def socket_path(id), do: Path.join(dir(), id <> ".sock")
  def exit_path(id), do: socket_path(id) <> ".exit"
  def final_path(id), do: socket_path(id) <> ".final"
  def text_final_path(id), do: socket_path(id) <> ".text"

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

  @doc "The holder's final machine-readable plain-text snapshot JSON."
  def read_final_text(id) do
    case File.read(text_final_path(id)) do
      {:ok, contents} -> Jason.decode(contents)
      {:error, _reason} -> {:error, :enoent}
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
        _ = File.rm(text_final_path(id))

        with :ok <- spawn_holder(id, opts),
             {:ok, socket} <- connect_with_retry(id, @connect_attempts) do
          {:ok, socket, false}
        end
    end
  end

  def connect(id) do
    path = socket_path(id)

    if File.exists?(path) do
      connect_endpoint(path)
    else
      {:error, :enoent}
    end
  end

  def send_input(socket, data), do: :gen_tcp.send(socket, <<@type_input, data::binary>>)

  def send_resize(socket, rows, cols),
    do: :gen_tcp.send(socket, <<@type_resize, rows::16, cols::16>>)

  def send_kill(socket), do: :gen_tcp.send(socket, <<@type_kill>>)

  @doc "Connect to a detached holder and wait until it has accepted a kill request."
  def kill(id, timeout \\ @kill_timeout_ms) when is_integer(timeout) and timeout > 0 do
    case connect(id) do
      {:ok, socket} ->
        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          with :ok <- await_hello(socket, deadline),
               :ok <- send_kill(socket) do
            await_exit(socket, deadline)
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ask the holder for a synthesized repaint (answered as a REPAINT frame).
  `cols` is the requesting viewer's width: the holder soft-wraps only when it
  matches the grid, hard-breaking otherwise. `history_budget` bounds the
  included scrollback bytes; zero renders only the current viewport.
  """
  def repaint_history_budget, do: @repaint_history_budget

  def send_repaint_req(socket, cols, history_budget \\ @repaint_history_budget) do
    budget = history_budget |> max(0) |> min(@repaint_history_budget)
    :gen_tcp.send(socket, <<@type_repaint_req, cols::16, budget::32>>)
  end

  @doc "Ask the holder for a bounded plain-text JSON snapshot."
  def send_text_snapshot_req(socket, lines, max_bytes),
    do: :gen_tcp.send(socket, <<@type_text_snapshot_req, lines::32, max_bytes::32>>)

  def send_processes_req(socket), do: :gen_tcp.send(socket, <<@type_processes_req>>)

  defp spawn_holder(id, opts) do
    binary = binary_path()
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    config =
      Jason.encode!(%{
        socket: socket_path(id),
        token: token,
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
    executable = if windows?(), do: "dala_holder.exe", else: "dala_holder"
    Path.join([:code.priv_dir(:dala), "bin", executable])
  end

  defp connect_endpoint(path) do
    if windows?(), do: connect_windows(path), else: connect_unix(path)
  end

  defp connect_unix(path) do
    :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
      :binary,
      packet: 4,
      active: true
    ])
  end

  defp connect_windows(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"host" => "127.0.0.1", "port" => port, "token" => token}}
         when is_integer(port) and port in 1..65_535 and is_binary(token) and token != "" <-
           Jason.decode(body),
         {:ok, socket} <-
           :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 4, active: false]) do
      result =
        with :ok <- :gen_tcp.send(socket, <<@type_auth, token::binary>>),
             :ok <- :inet.setopts(socket, active: true),
             do: :ok

      case result do
        :ok ->
          {:ok, socket}

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}
      end
    else
      {:error, _reason} = error ->
        error

      _invalid_endpoint ->
        {:error, :invalid_endpoint}
    end
  end

  defp await_hello(socket, deadline) do
    receive do
      {:tcp, ^socket, <<@type_hello, _payload::binary>>} -> :ok
      {:tcp, ^socket, _other_frame} -> await_hello(socket, deadline)
      {:tcp_closed, ^socket} -> {:error, :closed}
      {:tcp_error, ^socket, reason} -> {:error, reason}
    after
      remaining_timeout(deadline) -> {:error, :timeout}
    end
  end

  defp await_exit(socket, deadline) do
    receive do
      {:tcp, ^socket, <<@type_exit, _status::binary>>} -> :ok
      {:tcp, ^socket, _other_frame} -> await_exit(socket, deadline)
      {:tcp_closed, ^socket} -> :ok
      {:tcp_error, ^socket, reason} -> {:error, reason}
    after
      remaining_timeout(deadline) -> {:error, :timeout}
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
