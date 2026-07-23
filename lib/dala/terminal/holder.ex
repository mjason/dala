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
  # Protocol 7, bidirectional: request/ack payload is <<0 | 1>>.
  @type_query_owner 0x17
  @type_auth 0x10
  @type_input 0x11
  @type_resize 0x12
  @type_kill 0x13
  @type_repaint_req 0x14
  @type_text_snapshot_req 0x15
  @repaint_history_budget 512 * 1024
  @type_processes_req 0x16

  @connect_delay_ms 25
  @kill_timeout_ms 5_000
  @windows_hello_timeout_ms 5_000
  @stale_holder_retry_ms 1_000
  @startup_marker_retry_ms 2_000
  @attach_timeout_ms 30_000

  def type_hello, do: @type_hello
  def type_output, do: @type_output
  def type_exit, do: @type_exit
  def type_repaint, do: @type_repaint
  def type_cwd, do: @type_cwd
  def type_agent, do: @type_agent
  def type_text_snapshot, do: @type_text_snapshot
  def type_processes, do: @type_processes
  def type_query_owner, do: @type_query_owner

  def dir do
    base = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()
    Path.join(base, "dala-pty")
  end

  def socket_path(id), do: Path.join(dir(), id <> ".sock")
  def exit_path(id), do: socket_path(id) <> ".exit"
  def final_path(id), do: socket_path(id) <> ".final"
  def text_final_path(id), do: socket_path(id) <> ".text"
  def startup_error_path(id), do: socket_path(id) <> ".error"

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
    result = connect_existing(id, deadline_after(@windows_hello_timeout_ms))

    case result do
      {:ok, socket} ->
        {:ok, socket, true}

      {:error, reason} when reason in [:enoent, :econnrefused, :invalid_endpoint] ->
        # Only an endpoint that is demonstrably stale may be removed. A live
        # Windows listener that has not emitted HELLO yet must remain
        # untouched; deleting its endpoint can strand the running PTY and a
        # replacement cannot acquire its session lock.
        remove_stale_holder_files(id)

        spawn_deadline = deadline_after(@attach_timeout_ms)

        with {:ok, startup_id} <- spawn_holder(id, opts),
             {:ok, socket} <- connect_with_retry(id, spawn_deadline, startup_id) do
          {:ok, socket, false}
        end

      {:error, reason} ->
        {:error, {:holder_attach_failed, reason}}
    end
  end

  def connect(id) do
    connect(id, deadline_after(@windows_hello_timeout_ms))
  end

  defp connect(id, deadline) do
    path = socket_path(id)

    if File.exists?(path) do
      connect_endpoint(path, deadline)
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
    deadline = deadline_after(timeout)

    case connect(id, deadline) do
      {:ok, socket} ->
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

  def send_processes_req(socket, request_id)
      when is_integer(request_id) and request_id >= 0 and request_id <= 0xFFFFFFFFFFFFFFFF,
      do: :gen_tcp.send(socket, <<@type_processes_req, request_id::64>>)

  @doc "Enable or disable holder-owned terminal query replies (protocol 7)."
  def send_query_owner(socket, enabled) when is_boolean(enabled),
    do: :gen_tcp.send(socket, <<@type_query_owner, if(enabled, do: 1, else: 0)>>)

  defp spawn_holder(id, opts) do
    binary = binary_path()
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    startup_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    config =
      Jason.encode!(%{
        socket: socket_path(id),
        token: token,
        startup_id: startup_id,
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
      {_out, 0} -> {:ok, startup_id}
      {out, code} -> {:error, {:holder_spawn_failed, code, String.trim(out)}}
    end
  end

  defp connect_existing(id, deadline) do
    case connect(id, deadline) do
      {:error, reason} = error when reason in [:econnrefused, :closed] ->
        retry_existing_connection(id, deadline_after(@stale_holder_retry_ms), error)

      result ->
        result
    end
  end

  defp retry_existing_connection(id, deadline, last_error) do
    remaining = remaining_timeout(deadline)

    if remaining == 0 do
      last_error
    else
      Process.sleep(min(@connect_delay_ms, remaining))

      case connect(id, deadline) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, :enoent} = error ->
          error

        {:error, reason} = error when reason in [:econnrefused, :closed] ->
          retry_existing_connection(id, deadline, error)

        result ->
          result
      end
    end
  end

  defp connect_with_retry(id, deadline, startup_id) do
    case connect(id, deadline) do
      {:ok, socket} ->
        _ = clear_startup_error(id, startup_id)
        {:ok, socket}

      {:error, reason} = error
      when reason in [:enoent, :econnrefused, :closed, :timeout, :invalid_hello] ->
        case take_startup_error(id, startup_id) do
          {:error, message} ->
            # A lock/bind marker can come from a racing launch while its
            # holder is still completing HELLO. Give that endpoint a short,
            # bounded chance to become attachable before reporting our own
            # startup failure; fatal PTY/shell errors still fail quickly.
            retry_deadline =
              min(deadline, deadline_after(@startup_marker_retry_ms))

            case connect_existing(id, retry_deadline) do
              {:ok, socket} ->
                {:ok, socket}

              _ ->
                {:error, {:holder_start_failed, message}}
            end

          :none ->
            remaining = remaining_timeout(deadline)

            if remaining == 0 do
              error
            else
              Process.sleep(min(@connect_delay_ms, remaining))
              connect_with_retry(id, deadline, startup_id)
            end
        end

      result ->
        result
    end
  end

  defp remove_stale_holder_files(id) do
    _ = File.rm(socket_path(id))
    _ = File.rm(exit_path(id))
    _ = File.rm(final_path(id))
    _ = File.rm(text_final_path(id))
    _ = File.rm(startup_error_path(id))
  end

  defp take_startup_error(id, expected_id) do
    path = startup_error_path(id)

    case File.read(path) do
      {:ok, message} ->
        case String.split(message, "\n", parts: 2) do
          [^expected_id, detail] ->
            _ = File.rm(path)
            {:error, String.trim(detail)}

          _ ->
            :none
        end

      {:error, _reason} ->
        :none
    end
  end

  defp clear_startup_error(id, expected_id) do
    case File.read(startup_error_path(id)) do
      {:ok, message} when is_binary(message) ->
        case String.split(message, "\n", parts: 2) do
          [^expected_id, _detail] -> File.rm(startup_error_path(id))
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp binary_path do
    executable = if windows?(), do: "dala_holder.exe", else: "dala_holder"
    Path.join([:code.priv_dir(:dala), "bin", executable])
  end

  defp connect_endpoint(path, deadline) do
    if windows?(), do: connect_windows(path, deadline), else: connect_unix(path, deadline)
  end

  defp connect_unix(path, deadline) do
    :gen_tcp.connect(
      {:local, String.to_charlist(path)},
      0,
      [:binary, packet: 4, active: true],
      remaining_timeout(deadline)
    )
  end

  defp connect_windows(path, deadline) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"host" => "127.0.0.1", "port" => port, "token" => token}}
         when is_integer(port) and port in 1..65_535 and is_binary(token) and token != "" <-
           Jason.decode(body),
         {:ok, socket} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             port,
             [:binary, packet: 4, active: false],
             remaining_timeout(deadline)
           ) do
      result =
        with :ok <- :gen_tcp.send(socket, <<@type_auth, token::binary>>),
             {:ok, hello} <- :gen_tcp.recv(socket, 0, remaining_timeout(deadline)),
             true <- match?(<<@type_hello, _payload::binary>>, hello) do
          # Consume HELLO before returning so Windows callers cannot race PTY
          # startup. Re-emit it through the normal active-socket mailbox
          # contract expected by Server and the holder tests. Queue it while
          # active mode is still disabled so frames already waiting in the TCP
          # receive buffer cannot overtake HELLO when active mode is enabled.
          send(self(), {:tcp, socket, hello})
          :inet.setopts(socket, active: true)
        else
          false -> {:error, :invalid_hello}
          {:error, reason} -> {:error, reason}
        end

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

  defp deadline_after(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp windows?, do: match?({:win32, _}, :os.type())
end
