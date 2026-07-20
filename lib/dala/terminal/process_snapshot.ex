defmodule Dala.Terminal.ProcessSnapshot do
  @moduledoc """
  A shared, short-lived process-table snapshot.

  Multiplexer detection used to run one `ps` command per terminal on every
  cwd poll. This cache lets all terminal servers reuse one parsed snapshot
  for five seconds while keeping an explicit refresh for user-initiated
  viewer cleanup.
  """

  use GenServer

  @table __MODULE__
  @max_age_ms 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Return the cached process table, refreshing it when stale."
  def snapshot do
    now = System.monotonic_time(:millisecond)

    case lookup() do
      {captured_at, procs} when now - captured_at < @max_age_ms -> procs
      _stale_or_missing -> refresh_if_stale()
    end
  end

  @doc "Force a fresh process table, returning an empty list on failure."
  def refresh do
    call_or_capture(:refresh)
  end

  @doc false
  def parse(output) when is_binary(output) do
    for line <- String.split(output, "\n", trim: true),
        [pid, ppid | args] <- [String.split(String.trim(line), ~r/\s+/, trim: true)],
        args != [],
        {pid, ""} <- [Integer.parse(pid)],
        {ppid, ""} <- [Integer.parse(ppid)] do
      {pid, ppid, Enum.join(args, " ")}
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, put(capture_or([]))}
  end

  @impl true
  def handle_call(:refresh_if_stale, _from, state) do
    now = System.monotonic_time(:millisecond)

    case lookup() do
      {captured_at, procs} when now - captured_at < @max_age_ms ->
        {:reply, procs, state}

      _stale_or_missing ->
        procs = capture_or(state)
        {:reply, procs, put(procs)}
    end
  end

  def handle_call(:refresh, _from, state) do
    case capture() do
      {:ok, procs} -> {:reply, procs, put(procs)}
      :error -> {:reply, [], state}
    end
  end

  defp refresh_if_stale, do: call_or_capture(:refresh_if_stale)

  defp call_or_capture(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _reason -> capture_or([])
  end

  defp lookup do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, captured_at, procs}] -> {captured_at, procs}
      _missing -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put(procs) do
    :ets.insert(@table, {:snapshot, System.monotonic_time(:millisecond), procs})
    procs
  end

  defp capture_or(fallback) do
    case capture() do
      {:ok, procs} -> procs
      :error -> fallback
    end
  end

  defp capture do
    case System.cmd("ps", ["-eo", "pid=,ppid=,args="], stderr_to_stdout: true) do
      {output, 0} -> {:ok, parse(output)}
      {_output, _status} -> :error
    end
  rescue
    ErlangError -> :error
  end
end
