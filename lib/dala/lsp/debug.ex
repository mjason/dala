defmodule Dala.Lsp.Debug do
  @moduledoc """
  Live registry of LSP bridge connections, for the editor's debug window and
  for AI agents (`GET /lsp/debug` returns this as JSON, so a CLI agent can
  `curl` the health, traffic and current diagnostics of every server).

  Bridges report through the public ETS table — one row per connection,
  updated in the socket's own process; the GenServer only owns the table and
  prunes dead rows.
  """

  use GenServer

  @table __MODULE__
  @keep_recent 30
  @preview_bytes 300
  @prune_after_ms 10 * 60 * 1000

  # ---------------------------------------------------------------- client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers a new bridge; returns the entry id."
  def register(meta) do
    id = System.unique_integer([:positive, :monotonic])

    entry =
      Map.merge(meta, %{
        id: id,
        status: "running",
        exit_status: nil,
        started_at: System.system_time(:millisecond),
        last_activity: System.system_time(:millisecond),
        in_count: 0,
        out_count: 0,
        recent: [],
        diagnostics: nil
      })

    :ets.insert(@table, {id, entry})
    id
  end

  @doc "Records one JSON-RPC message crossing the bridge (`:in` = client→server)."
  def record(id, direction, message) do
    with [{^id, entry}] <- :ets.lookup(@table, id) do
      preview = binary_part(message, 0, min(byte_size(message), @preview_bytes))

      recent =
        [%{dir: direction, at: System.system_time(:millisecond), preview: preview} | entry.recent]
        |> Enum.take(@keep_recent)

      entry = %{
        entry
        | recent: recent,
          last_activity: System.system_time(:millisecond),
          in_count: entry.in_count + if(direction == :in, do: 1, else: 0),
          out_count: entry.out_count + if(direction == :out, do: 1, else: 0)
      }

      entry =
        if direction == :out and String.contains?(message, "publishDiagnostics") do
          %{entry | diagnostics: extract_diagnostics(message) || entry.diagnostics}
        else
          entry
        end

      :ets.insert(@table, {id, entry})
    end

    :ok
  end

  @doc "Marks a bridge as exited (kept for a while for post-mortem reading)."
  def exited(id, exit_status) do
    with [{^id, entry}] <- :ets.lookup(@table, id) do
      :ets.insert(
        @table,
        {id,
         %{
           entry
           | status: "exited",
             exit_status: exit_status,
             last_activity: System.system_time(:millisecond)
         }}
      )
    end

    :ok
  end

  @doc "Every known bridge, newest first, with the stderr tail attached."
  def snapshot do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} ->
      entry
      |> Map.update!(:recent, &Enum.reverse/1)
      |> Map.put(:stderr_tail, stderr_tail(entry))
    end)
    |> Enum.sort_by(& &1.started_at, :desc)
  end

  @doc "Path for a bridge's stderr capture file."
  def stderr_path(id) do
    dir = Path.join(System.tmp_dir!(), "dala-lsp")
    File.mkdir_p!(dir)
    Path.join(dir, "server-#{id}.stderr.log")
  end

  # ---------------------------------------------------------------- server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = System.system_time(:millisecond) - @prune_after_ms

    for {id, %{status: "exited", last_activity: at}} <- :ets.tab2list(@table), at < cutoff do
      File.rm(stderr_path(id))
      :ets.delete(@table, id)
    end

    schedule_prune()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_prune, do: Process.send_after(self(), :prune, 60_000)

  # A compact diagnostics snapshot: enough for an agent to see what's wrong
  # without replaying the message stream.
  defp extract_diagnostics(message) do
    with {:ok, %{"method" => "textDocument/publishDiagnostics", "params" => params}} <-
           Jason.decode(message) do
      %{
        uri: params["uri"],
        count: length(params["diagnostics"] || []),
        items:
          for diag <- Enum.take(params["diagnostics"] || [], 20) do
            %{
              message: String.slice(diag["message"] || "", 0, 200),
              severity: diag["severity"],
              line: get_in(diag, ["range", "start", "line"])
            }
          end
      }
    else
      _ -> nil
    end
  end

  defp stderr_tail(entry) do
    path = stderr_path(entry.id)

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        offset = max(size - 2048, 0)

        case File.open(path, [:read], fn file ->
               :file.pread(file, offset, size - offset)
             end) do
          {:ok, {:ok, data}} -> data
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
