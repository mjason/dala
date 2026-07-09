defmodule Dala.Terminal.Server do
  @moduledoc """
  Owns the PTY of a single terminal session.

  Receives `{:pty_data, id, chunk}` / `{:pty_exit, id, status}` from the
  `Dala.Pty` reader thread, persists chunks to the scrollback cache and
  broadcasts them to the `terminal:{id}` channel topic. Session lifecycle
  changes go through internal Ash actions so their PubSub publications reach
  the typed channels.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Dala.Terminal.Scrollback

  @cwd_poll_ms 2_000
  @force_stop_ms 5_000

  # Host-terminal identity leaked from the parent process would make shell
  # integrations and TUIs (opencode, …) negotiate protocols the web terminal
  # does not speak (ghostty/kitty extensions, …).
  @env_remove ~w(
    TERM_PROGRAM TERM_PROGRAM_VERSION
    GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_INTEGRATION_NO_SUDO
    KITTY_WINDOW_ID KITTY_PID KITTY_INSTALLATION_DIR KITTY_PUBLIC_KEY
    WEZTERM_EXECUTABLE WEZTERM_CONFIG_FILE WEZTERM_PANE WEZTERM_UNIX_SOCKET
    ITERM_SESSION_ID LC_TERMINAL LC_TERMINAL_VERSION
    VTE_VERSION WT_SESSION WT_PROFILE_ID
    TMUX TMUX_PANE STY ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID
    VSCODE_INJECTION VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_IPC_HANDLE
  )

  # Replayed scrollback re-applies whatever terminal modes old programs had
  # enabled (mouse tracking, bracketed paste, alt-screen, hidden cursor).
  # When the shell those programs lived in is gone, that state is stale and
  # turns mouse movement into `35;36M`-style input garbage. This sequence
  # switches every such mode off; it is appended to the stream whenever the
  # PTY dies or a fresh PTY attaches to existing scrollback, so replays
  # always end in a sane state.
  @mode_reset "\e[?1000l\e[?1002l\e[?1003l\e[?1005l\e[?1006l" <>
                "\e[?2004l\e[?1049l\e[?1l\e[?7h\e[?25h\e[0m"

  ## Client

  def ensure_started(%Dala.Terminal.Session{} = session) do
    case DynamicSupervisor.start_child(Dala.Terminal.ServerSupervisor, {__MODULE__, session}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.id))
  end

  @doc "Write keyboard input (raw bytes) to the PTY."
  def input(id, data), do: cast_if_alive(id, {:input, data})

  @doc """
  Reports a connected client's viewport size.

  A session is shared: several clients (desktop, phone, another tab) may be
  attached at once, but the single underlying PTY can only have one size. As
  in tmux/screen, the PTY is sized to the *smallest* connected viewport so
  its output never overflows the most constrained client. `client` is the
  channel process; the server tracks it and drops its size when it exits.
  """
  def resize(id, client, rows, cols) when is_pid(client),
    do: cast_if_alive(id, {:resize, client, rows, cols})

  @doc "Current PTY size as `{rows, cols}`, or nil if the session is not running."
  def viewport(id) do
    case whereis(id) do
      nil -> nil
      pid -> GenServer.call(pid, :viewport)
    end
  end

  @doc "Kill the shell. The session is marked exited once the PTY reports it."
  def stop(id), do: cast_if_alive(id, :shutdown)

  @doc """
  Kill the shell and block until the server has fully stopped (i.e. the exit
  has been recorded). Used before destroying a session so no output trickles
  into the scrollback cache after it is cleared.
  """
  def shutdown_and_wait(id, timeout \\ 10_000) do
    case whereis(id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        GenServer.cast(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            :ok
        end
    end
  end

  def alive?(id), do: whereis(id) != nil

  def whereis(id) do
    case Registry.lookup(Dala.Terminal.Registry, to_string(id)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via(id), do: {:via, Registry, {Dala.Terminal.Registry, to_string(id)}}

  defp cast_if_alive(id, message) do
    case whereis(id) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  ## Server

  @impl true
  def init(session) do
    id = to_string(session.id)

    env = [
      {"TERM", "xterm-256color"},
      {"COLORTERM", "truecolor"}
    ]

    try do
      pty = Dala.Pty.open(id, session.shell, [], session.cwd, env, @env_remove, 24, 80)

      state = %{
        id: id,
        session: session,
        pty: pty,
        child_pid: Dala.Pty.child_pid(pty),
        cwd: session.cwd,
        seq: Scrollback.last_seq(id),
        # Per-client viewport sizes; the PTY tracks their minimum.
        clients: %{},
        size: {24, 80}
      }

      {:ok, state, {:continue, :post_init}}
    rescue
      error -> {:stop, {:pty_open_failed, Exception.message(error)}}
    end
  end

  @impl true
  def handle_continue(:post_init, state) do
    Scrollback.set_limit(state.id, state.session.scrollback_limit)

    # A fresh PTY attaching to existing scrollback: neutralize terminal
    # modes left over from the previous shell's programs.
    if Scrollback.last_seq(state.id) >= 0 do
      emit(state.id, @mode_reset)
    end

    state = %{state | session: Dala.Terminal.mark_running!(state.session)}
    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:viewport, _from, state) do
    {:reply, state.size, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Kill the child shell now rather than waiting for the PTY resource to be
    # garbage-collected, and reconcile the session so clients stop showing a
    # terminal whose server is gone (covers crashes, not just clean exits).
    safe_pty(fn -> Dala.Pty.kill(state.pty) end)

    case Dala.Terminal.get_session(state.id) do
      {:ok, %{status: :running} = session} ->
        Dala.Terminal.mark_exited(session, %{exit_code: nil})

      _ ->
        :ok
    end

    :ok
  rescue
    _error -> :ok
  end

  @impl true
  def handle_cast({:input, data}, state) do
    safe_pty(fn -> Dala.Pty.write(state.pty, data) end)
    {:noreply, state}
  end

  def handle_cast({:resize, client, rows, cols}, state) do
    # Monitor each client the first time we hear from it, so its size is
    # dropped when the channel process exits.
    unless Map.has_key?(state.clients, client), do: Process.monitor(client)

    clients = Map.put(state.clients, client, {rows, cols})
    {:noreply, apply_min_size(%{state | clients: clients})}
  end

  def handle_cast(:shutdown, state) do
    safe_pty(fn -> Dala.Pty.kill(state.pty) end)
    Process.send_after(self(), :force_stop, @force_stop_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_data, id, data}, %{id: id} = state) do
    seq = emit(id, data)
    {:noreply, %{state | seq: seq}}
  end

  def handle_info({:pty_exit, id, status}, %{id: id} = state) do
    # Whatever was running is gone; make sure clients (and future replays)
    # drop its mouse/paste/alt-screen modes.
    emit(id, @mode_reset)

    case Dala.Terminal.mark_exited(state.session, %{exit_code: status}) do
      {:ok, _session} -> :ok
      {:error, error} -> Logger.warning("could not mark session #{id} exited: #{inspect(error)}")
    end

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.clients, pid) do
    # A client disconnected — drop its size so a larger remaining client can
    # reclaim the PTY dimensions.
    {:noreply, apply_min_size(%{state | clients: Map.delete(state.clients, pid)})}
  end

  def handle_info(:force_stop, state) do
    # The PTY did not report an exit within the timeout after kill.
    case Dala.Terminal.mark_exited(state.session, %{exit_code: nil}) do
      {:ok, _session} -> :ok
      {:error, error} -> Logger.warning("could not mark session exited: #{inspect(error)}")
    end

    {:stop, :normal, state}
  end

  def handle_info(:poll_cwd, state) do
    state =
      case current_cwd(state.child_pid) do
        nil ->
          state

        cwd when cwd == state.cwd ->
          state

        cwd ->
          case Dala.Terminal.update_cwd(state.session, %{cwd: cwd}) do
            {:ok, session} -> %{state | cwd: cwd, session: session}
            {:error, _error} -> state
          end
      end

    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  defp current_cwd(nil), do: nil

  defp current_cwd(child_pid) do
    case File.read_link("/proc/#{child_pid}/cwd") do
      {:ok, cwd} -> cwd
      {:error, _reason} -> nil
    end
  end

  defp safe_pty(fun) do
    fun.()
  rescue
    _error -> :ok
  end

  # Sizes the PTY to the smallest connected client's viewport. No-op while no
  # clients are attached (keep the last size) or when the minimum is unchanged.
  defp apply_min_size(state) do
    case Map.values(state.clients) do
      [] ->
        state

      sizes ->
        rows = sizes |> Enum.map(&elem(&1, 0)) |> Enum.min()
        cols = sizes |> Enum.map(&elem(&1, 1)) |> Enum.min()
        size = {rows, cols}

        if size == state.size do
          state
        else
          safe_pty(fn -> Dala.Pty.resize(state.pty, rows, cols) end)
          # Tell every attached client the new PTY size. Desktop clients that
          # drive their own size ignore it; "follower" clients (e.g. a phone
          # watching a desktop session) render at this size and scale to fit.
          DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "resize", %{rows: rows, cols: cols})
          %{state | size: size}
        end
    end
  end

  # Appends to the scrollback cache and broadcasts to connected clients.
  defp emit(id, data) do
    seq = Scrollback.append(id, data)

    DalaWeb.Endpoint.broadcast("terminal:" <> id, "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    seq
  end
end
