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
    path = Path.join(dir, "scrollback.dets")
    file = String.to_charlist(path)

    :ok = open_table(file, path)
    {:ok, %{}}
  end

  # The scrollback is a disposable cache. If the DETS file is corrupt or was
  # left unclean by a hard kill, drop it and start fresh instead of failing
  # every read/write.
  defp open_table(file, path) do
    case :dets.open_file(@table, file: file, type: :set, auto_save: 10_000) do
      {:ok, @table} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("scrollback cache corrupt (#{inspect(reason)}); recreating")
        File.rm(path)
        {:ok, @table} = :dets.open_file(@table, file: file, type: :set, auto_save: 10_000)
        :ok
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
  end

  @impl true
  def handle_call({:append, session_id, data}, _from, state) do
    meta = get_meta(session_id)
    seq = meta.next

    safe_insert({{session_id, seq}, data})

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
          [{_key, data}] <- [safe_lookup({session_id, seq})] do
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
      safe_delete({session_id, seq})
    end

    safe_delete({session_id, :meta})
    {:reply, :ok, state}
  end

  ## Helpers

  # The scrollback is a cache: a corrupted DETS record (e.g. after an unclean
  # shutdown) must never crash this server. Damaged entries read as missing
  # and get overwritten by subsequent writes.
  defp safe_lookup(key) do
    case :dets.lookup(@table, key) do
      results when is_list(results) -> results
      {:error, reason} -> log_corruption(reason) && []
    end
  end

  defp safe_insert(record) do
    case :dets.insert(@table, record) do
      :ok -> :ok
      {:error, reason} -> log_corruption(reason)
    end
  end

  defp safe_delete(key) do
    case :dets.delete(@table, key) do
      :ok -> :ok
      {:error, reason} -> log_corruption(reason)
    end
  end

  defp log_corruption(reason) do
    require Logger
    Logger.warning("scrollback cache read/write failed: #{inspect(reason)}")
    true
  end

  defp get_meta(session_id) do
    case safe_lookup({session_id, :meta}) do
      [{_key, %Meta{} = meta}] -> %{meta | limit: meta.limit || @default_limit}
      _ -> %Meta{limit: @default_limit}
    end
  end

  defp put_meta(session_id, meta) do
    safe_insert({{session_id, :meta}, meta})
  end

  defp trim(session_id, %Meta{} = meta) do
    if meta.bytes > meta.limit and meta.first < meta.next do
      freed =
        case safe_lookup({session_id, meta.first}) do
          [{_key, data}] ->
            safe_delete({session_id, meta.first})
            byte_size(data)

          _ ->
            0
        end

      trim(session_id, %{meta | first: meta.first + 1, bytes: meta.bytes - freed})
    else
      meta
    end
  end
end
