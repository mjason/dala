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

  @doc "Resize the PTY."
  def resize(id, rows, cols), do: cast_if_alive(id, {:resize, rows, cols})

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
      pty = Dala.Pty.open(id, session.shell, [], session.cwd, env, 24, 80)

      state = %{
        id: id,
        session: session,
        pty: pty,
        child_pid: Dala.Pty.child_pid(pty),
        cwd: session.cwd,
        seq: Scrollback.last_seq(id)
      }

      {:ok, state, {:continue, :post_init}}
    rescue
      error -> {:stop, {:pty_open_failed, Exception.message(error)}}
    end
  end

  @impl true
  def handle_continue(:post_init, state) do
    Scrollback.set_limit(state.id, state.session.scrollback_limit)
    state = %{state | session: Dala.Terminal.mark_running!(state.session)}
    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    safe_pty(fn -> Dala.Pty.write(state.pty, data) end)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, state) do
    safe_pty(fn -> Dala.Pty.resize(state.pty, rows, cols) end)
    {:noreply, state}
  end

  def handle_cast(:shutdown, state) do
    safe_pty(fn -> Dala.Pty.kill(state.pty) end)
    Process.send_after(self(), :force_stop, @force_stop_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_data, id, data}, %{id: id} = state) do
    seq = Scrollback.append(id, data)

    DalaWeb.Endpoint.broadcast("terminal:" <> id, "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    {:noreply, %{state | seq: seq}}
  end

  def handle_info({:pty_exit, id, status}, %{id: id} = state) do
    case Dala.Terminal.mark_exited(state.session, %{exit_code: status}) do
      {:ok, _session} -> :ok
      {:error, error} -> Logger.warning("could not mark session #{id} exited: #{inspect(error)}")
    end

    {:stop, :normal, state}
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
end
