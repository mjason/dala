defmodule DalaWeb.LspSocket do
  @moduledoc """
  WebSocket ↔ stdio bridge for language servers.

  One WebSocket connection = one LSP process: the browser-side client owns
  the whole session (initialize, didOpen, …), so no request multiplexing is
  needed. Each WS text frame is a single JSON-RPC message; on the stdio side
  the base protocol's Content-Length framing is added/stripped. The process
  dies with the connection.

  Every connection reports to `Dala.Lsp.Debug` (traffic counters, recent
  messages, diagnostics snapshots), and the server's stderr is captured to a
  file — stdout carries the protocol, so stderr is where crash reasons go.
  """

  @behaviour WebSock

  require Logger

  alias Dala.Lsp.{Debug, Discovery, Framing}

  @impl true
  def init(%{root: root, path: path, server: index}) do
    case Enum.find(Discovery.servers(root, path), &(&1.id == index)) do
      nil ->
        {:stop, :normal, {1008, "no such language server"}, %{port: nil, buffer: ""}}

      %{command: command, name: name} ->
        debug_id =
          Debug.register(%{
            root: root,
            path: path,
            name: name,
            command: Enum.join(command, " ")
          })

        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            :hide,
            args: ["-c", shell_command(command, Debug.stderr_path(debug_id))],
            cd: root
          ])

        Logger.info("lsp: #{name} started for #{root} (#{Path.basename(path)})")
        {:ok, %{port: port, buffer: "", name: name, debug_id: debug_id}}
    end
  end

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    if state.port do
      Debug.record(state.debug_id, :in, message)
      Port.command(state.port, Framing.encode(message))
    end

    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {messages, rest} = Framing.decode(state.buffer <> chunk)
    state = %{state | buffer: rest}

    case messages do
      [] ->
        {:ok, state}

      _ ->
        Enum.each(messages, &Debug.record(state.debug_id, :out, &1))
        {:push, Enum.map(messages, &{:text, &1}), state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("lsp: #{state.name} exited with #{status}")
    Debug.exited(state.debug_id, status)
    {:stop, :normal, {1011, "language server exited"}, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{port: port, debug_id: debug_id} = state) when is_port(port) do
    Debug.exited(debug_id, nil)

    # Port.close only closes stdio; the wrapper shell exec'd the server, so
    # its os_pid IS the server — ask it to die too.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    Port.close(port)
    _ = state
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # `exec cmd args… 2> stderr_file` — exec keeps the server as the port's
  # os_pid; stderr goes to the capture file without touching the protocol
  # stream on stdout.
  defp shell_command(command, stderr_path) do
    Enum.map_join(["exec" | command], " ", &shell_escape/1) <>
      " 2> " <> shell_escape(stderr_path)
  end

  defp shell_escape(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"
end
