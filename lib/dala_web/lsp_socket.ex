defmodule DalaWeb.LspSocket do
  @moduledoc """
  WebSocket ↔ stdio bridge for language servers.

  One WebSocket connection = one LSP process: the browser-side client owns
  the whole session (initialize, didOpen, …), so no request multiplexing is
  needed. Each WS text frame is a single JSON-RPC message; on the stdio side
  the base protocol's Content-Length framing is added/stripped. The process
  dies with the connection.
  """

  @behaviour WebSock

  require Logger

  alias Dala.Lsp.{Discovery, Framing}

  @impl true
  def init(%{root: root, path: path, server: index}) do
    case Enum.find(Discovery.servers(root, path), &(&1.id == index)) do
      nil ->
        {:stop, :normal, {1008, "no such language server"}, %{port: nil, buffer: ""}}

      %{command: [bin | args], name: name} ->
        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :hide,
            args: args,
            cd: root,
            env: [{~c"PWD", String.to_charlist(root)}]
          ])

        Logger.info("lsp: #{name} started for #{root} (#{Path.basename(path)})")
        {:ok, %{port: port, buffer: "", name: name}}
    end
  end

  @impl true
  def handle_in({message, [opcode: :text]}, state) do
    if state.port, do: Port.command(state.port, Framing.encode(message))
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {messages, rest} = Framing.decode(state.buffer <> chunk)
    state = %{state | buffer: rest}

    case messages do
      [] -> {:ok, state}
      _ -> {:push, Enum.map(messages, &{:text, &1}), state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("lsp: #{state.name} exited with #{status}")
    {:stop, :normal, {1011, "language server exited"}, %{state | port: nil}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    # Port.close only closes stdio; ask the OS process to die too.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
