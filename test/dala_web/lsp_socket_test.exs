defmodule DalaWeb.LspSocketTest do
  use ExUnit.Case, async: true

  alias DalaWeb.LspSocket

  @fake_server """
  #!/usr/bin/env python3
  import json, sys

  def read_message():
      length = None
      while True:
          line = sys.stdin.buffer.readline().decode()
          if line in ("\\r\\n", "\\n", ""):
              break
          name, _, value = line.partition(":")
          if name.strip().lower() == "content-length":
              length = int(value.strip())
      return json.loads(sys.stdin.buffer.read(length)) if length else None

  def write_message(payload):
      body = json.dumps(payload).encode()
      sys.stdout.buffer.write(b"Content-Length: %d\\r\\n\\r\\n" % len(body) + body)
      sys.stdout.buffer.flush()

  while True:
      message = read_message()
      if message is None or message.get("method") == "exit":
          break
      if "id" in message:
          write_message({"jsonrpc": "2.0", "id": message["id"],
                         "result": {"capabilities": {"hoverProvider": True}}})
  """

  setup do
    root =
      Dala.TestPlatform.normalize_path(
        Path.join(System.tmp_dir!(), "lsp-socket-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> rm_rf_retry(root, 20) end)
    File.mkdir_p!(Path.join(root, ".dala"))

    command =
      if Dala.TestPlatform.windows?() do
        source = Path.join(root, "fake_lsp.erl")
        File.cp!("test/support/fake_lsp.erl", source)
        {_, 0} = System.cmd(System.find_executable("erlc.exe"), ["-o", root, source])
        [System.find_executable("erl.exe"), "-noshell", "-pa", root, "-s", "fake_lsp", "main"]
      else
        server = Path.join(root, "fake-lsp.py")
        File.write!(server, @fake_server)
        File.chmod!(server, 0o755)
        [System.find_executable("python3") || System.find_executable("python"), server]
      end

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      Jason.encode!(%{python: [%{command: command}]})
    )

    {:ok, root: root}
  end

  defp rm_rf_retry(path, attempts) do
    case File.rm_rf(path) do
      {:ok, _files} ->
        :ok

      {:error, _reason, _file} when attempts > 0 ->
        receive do
        after
          50 -> rm_rf_retry(path, attempts - 1)
        end

      {:error, reason, file} ->
        flunk("could not remove #{file}: #{inspect(reason)}")
    end
  end

  test "bridges JSON-RPC over the port and back", %{root: root} do
    assert {:ok, state} = LspSocket.init(%{root: root, path: "main.py", server: 0})

    request = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    assert {:ok, state} = LspSocket.handle_in({request, [opcode: :text]}, state)

    assert {:push, [{:text, response}], _state} = await_push(state)

    assert %{"id" => 1, "result" => %{"capabilities" => %{"hoverProvider" => true}}} =
             Jason.decode!(response)

    LspSocket.terminate(:normal, state)
  end

  defp await_push(state) do
    receive do
      {port, {:data, chunk}} when is_port(port) ->
        case LspSocket.handle_info({port, {:data, chunk}}, state) do
          {:ok, state} -> await_push(state)
          result -> result
        end

      {port, {:exit_status, status}} when is_port(port) ->
        flunk("language server exited with #{status}; buffered #{inspect(state.buffer)}")
    after
      5_000 -> flunk("language server did not respond; buffered #{inspect(state.buffer)}")
    end
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
