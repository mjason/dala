defmodule Dala.Terminal.WaiterLimiter do
  @moduledoc false

  use GenServer

  @max_waiters 128

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def acquire(owner), do: GenServer.call(__MODULE__, {:acquire, owner})
  def release(owner), do: GenServer.cast(__MODULE__, {:release, owner})

  @impl true
  def init(:ok), do: {:ok, %{total: 0, owners: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, _owner}, _from, %{total: total} = state)
      when total >= @max_waiters,
      do: {:reply, {:error, :limit}, state}

  def handle_call({:acquire, owner}, _from, state) do
    {owners, monitors} =
      case state.owners do
        %{^owner => count} ->
          {Map.put(state.owners, owner, count + 1), state.monitors}

        _ ->
          monitor = Process.monitor(owner)
          {Map.put(state.owners, owner, 1), Map.put(state.monitors, monitor, owner)}
      end

    {:reply, :ok, %{state | total: state.total + 1, owners: owners, monitors: monitors}}
  end

  @impl true
  def handle_cast({:release, owner}, state), do: {:noreply, release_one(state, owner)}

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    count = Map.get(state.owners, owner, 0)

    {:noreply,
     %{
       state
       | total: max(0, state.total - count),
         owners: Map.delete(state.owners, owner),
         monitors: Map.delete(state.monitors, monitor)
     }}
  end

  defp release_one(state, owner) do
    case Map.get(state.owners, owner, 0) do
      0 ->
        state

      1 ->
        {monitor, monitors} = pop_monitor(state.monitors, owner)
        if monitor, do: Process.demonitor(monitor, [:flush])

        %{
          state
          | total: max(0, state.total - 1),
            owners: Map.delete(state.owners, owner),
            monitors: monitors
        }

      count ->
        %{
          state
          | total: max(0, state.total - 1),
            owners: Map.put(state.owners, owner, count - 1)
        }
    end
  end

  defp pop_monitor(monitors, owner) do
    case Enum.find(monitors, fn {_monitor, monitored} -> monitored == owner end) do
      nil -> {nil, monitors}
      {monitor, _owner} -> {monitor, Map.delete(monitors, monitor)}
    end
  end
end
