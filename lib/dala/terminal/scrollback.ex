defmodule Dala.Terminal.Scrollback do
  @moduledoc """
  DETS-backed scrollback cache for terminal sessions.

  Output chunks are stored per session as `{{session_id, seq}, binary}` with a
  `{{session_id, :meta}, meta}` record tracking sequence bounds, total bytes and
  the per-session byte limit. When a session exceeds its limit the oldest
  chunks are dropped, so a refresh or reconnect can always replay up to
  `limit` bytes of recent output — even across BEAM restarts.
  """

  use GenServer

  @table :dala_scrollback
  @default_limit 5 * 1024 * 1024

  defmodule Meta do
    @moduledoc false
    defstruct first: 0, next: 0, bytes: 0, limit: nil
  end

  ## Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Appends a chunk and returns its sequence number."
  @spec append(String.t(), binary()) :: non_neg_integer()
  def append(session_id, data) when is_binary(data) do
    GenServer.call(__MODULE__, {:append, session_id, data})
  end

  @doc "Returns the sequence number of the most recent chunk, or -1 when empty."
  @spec last_seq(String.t()) :: integer()
  def last_seq(session_id) do
    GenServer.call(__MODULE__, {:last_seq, session_id})
  end

  @doc """
  Returns the buffered output as a list of `{seq, binary}` tuples in order.
  """
  @spec replay(String.t()) :: [{non_neg_integer(), binary()}]
  def replay(session_id) do
    GenServer.call(__MODULE__, {:replay, session_id}, 30_000)
  end

  @doc "Updates the byte limit for a session, trimming immediately if needed."
  @spec set_limit(String.t(), pos_integer()) :: :ok
  def set_limit(session_id, limit) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:set_limit, session_id, limit})
  end

  @doc "Removes all buffered output for a session."
  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    GenServer.call(__MODULE__, {:clear, session_id})
  end

  ## Server

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir) || Application.fetch_env!(:dala, :data_dir)
    File.mkdir_p!(dir)
    file = Path.join(dir, "scrollback.dets") |> String.to_charlist()

    {:ok, @table} = :dets.open_file(@table, file: file, type: :set, auto_save: 10_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
  end

  @impl true
  def handle_call({:append, session_id, data}, _from, state) do
    meta = get_meta(session_id)
    seq = meta.next

    :ok = :dets.insert(@table, {{session_id, seq}, data})

    meta = %{meta | next: seq + 1, bytes: meta.bytes + byte_size(data)}
    meta = trim(session_id, meta)
    put_meta(session_id, meta)

    {:reply, seq, state}
  end

  def handle_call({:last_seq, session_id}, _from, state) do
    {:reply, get_meta(session_id).next - 1, state}
  end

  def handle_call({:replay, session_id}, _from, state) do
    meta = get_meta(session_id)

    chunks =
      for seq <- meta.first..(meta.next - 1)//1,
          [{_key, data}] <- [:dets.lookup(@table, {session_id, seq})] do
        {seq, data}
      end

    {:reply, chunks, state}
  end

  def handle_call({:set_limit, session_id, limit}, _from, state) do
    meta = %{get_meta(session_id) | limit: limit}
    put_meta(session_id, trim(session_id, meta))
    {:reply, :ok, state}
  end

  def handle_call({:clear, session_id}, _from, state) do
    meta = get_meta(session_id)

    for seq <- meta.first..(meta.next - 1)//1 do
      :dets.delete(@table, {session_id, seq})
    end

    :dets.delete(@table, {session_id, :meta})
    {:reply, :ok, state}
  end

  ## Helpers

  defp get_meta(session_id) do
    case :dets.lookup(@table, {session_id, :meta}) do
      [{_key, %Meta{} = meta}] -> %{meta | limit: meta.limit || @default_limit}
      [] -> %Meta{limit: @default_limit}
    end
  end

  defp put_meta(session_id, meta) do
    :ok = :dets.insert(@table, {{session_id, :meta}, meta})
  end

  defp trim(session_id, %Meta{} = meta) do
    if meta.bytes > meta.limit and meta.first < meta.next do
      freed =
        case :dets.lookup(@table, {session_id, meta.first}) do
          [{_key, data}] ->
            :dets.delete(@table, {session_id, meta.first})
            byte_size(data)

          [] ->
            0
        end

      trim(session_id, %{meta | first: meta.first + 1, bytes: meta.bytes - freed})
    else
      meta
    end
  end
end
