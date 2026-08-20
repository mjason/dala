defmodule DalaWeb.LspSocketTest do
  use ExUnit.Case, async: true

  alias DalaWeb.LspSocket

  @fake_server """
  defmodule FakeLsp do
    def run do
      case read_message() do
        :eof ->
          :ok

        body ->
          if String.contains?(body, ~s("method":"exit")) do
            :ok
          else
            response =
              ~s({"jsonrpc":"2.0","id":1,"result":{"capabilities":{"hoverProvider":true}}})

            IO.binwrite(:stdio, [
              "Content-Length: ",
              Integer.to_string(byte_size(response)),
              "\r\n\r\n",
              response
            ])

            run()
          end
      end
    end

    defp read_message do
      case IO.read(:stdio, :line) do
        :eof -> :eof
        line -> read_headers(line, nil)
      end
    end

    defp read_headers(line, length) when line in ["\r\n", "\n"] do
      if length, do: IO.binread(:stdio, length), else: :eof
    end

    defp read_headers(line, length) do
      length =
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            if String.downcase(String.trim(name)) == "content-length",
              do: value |> String.trim() |> String.to_integer(),
              else: length

          _ ->
            length
        end

      case IO.read(:stdio, :line) do
        :eof -> :eof
        next -> read_headers(next, length)
      end
    end
  end

  FakeLsp.run()
  """

  setup do
    root =
      Dala.Paths.expand_user(
        Path.join(System.tmp_dir!(), "lsp-socket-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, ".dala"))

    server = Path.join(root, "fake-lsp.exs")
    File.write!(server, @fake_server)
    Dala.Platform.chmod!(server, 0o755)

    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      Jason.encode!(%{python: [%{command: [elixir, server]}]})
    )

    {:ok, root: root}
  end

  test "bridges JSON-RPC over the port and back", %{root: root} do
    assert {:ok, state} = LspSocket.init(%{root: root, path: "main.py", server: 0})

    request = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    assert {:ok, state} = LspSocket.handle_in({request, [opcode: :text]}, state)

    assert_receive {port, {:data, chunk}} when is_port(port), 5_000

    assert {:push, [{:text, response}], _state} =
             LspSocket.handle_info({port, {:data, chunk}}, state)

    assert %{"id" => 1, "result" => %{"capabilities" => %{"hoverProvider" => true}}} =
             Jason.decode!(response)

    LspSocket.terminate(:normal, state)
  end

  test "unknown server index refuses the connection", %{root: root} do
    assert {:stop, :normal, {1008, _}, _state} =
             LspSocket.init(%{root: root, path: "main.py", server: 9})
  end

  test "server exit stops the socket", %{root: root} do
    assert {:ok, state} = LspSocket.init(%{root: root, path: "main.py", server: 0})

    exit_note = ~s({"jsonrpc":"2.0","method":"exit"})
    assert {:ok, state} = LspSocket.handle_in({exit_note, [opcode: :text]}, state)

    assert_receive {port, {:exit_status, 0}} when is_port(port), 5_000

    assert {:stop, :normal, {1011, _}, _state} =
             LspSocket.handle_info({port, {:exit_status, 0}}, state)
  end
end
