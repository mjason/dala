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
    root = Path.join(System.tmp_dir!(), "lsp-socket-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, ".dala"))

    server = Path.join(root, "fake-lsp.py")
    File.write!(server, @fake_server)
    File.chmod!(server, 0o755)

    python = System.find_executable("python3")

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      Jason.encode!(%{python: [%{command: [python, server]}]})
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
