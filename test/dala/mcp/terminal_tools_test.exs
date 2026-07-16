defmodule Dala.Mcp.TerminalToolsTest do
  use Dala.DataCase, async: false

  alias Dala.Mcp.{Registry, TerminalTools}
  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  setup do
    Dala.Settings.Mcp.current()
    Dala.Settings.Mcp.set_terminal_access(true, true)

    session =
      Dala.Terminal.create_session!(%{
        shell: "/bin/bash",
        name: "mcp-test",
        cwd: System.tmp_dir!()
      })

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      id = to_string(session.id)
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
    end)

    {:ok, session: session}
  end

  test "terminal tools are permission-gated in both discovery and execution", %{session: session} do
    Dala.Settings.Mcp.set_terminal_access(false, false)
    names = Registry.tools() |> Enum.map(& &1["name"])
    refute "list_terminal_sessions" in names
    refute "send_terminal_message" in names
    refute "send_terminal_keys" in names

    assert {:error, message} = TerminalTools.call("read_terminal", %{"session" => session.id})
    assert message =~ "read access is disabled"

    Dala.Settings.Mcp.set_terminal_access(true, false)
    names = Registry.tools() |> Enum.map(& &1["name"])
    assert "list_terminal_sessions" in names
    assert "read_terminal" in names
    assert "wait_terminal" in names
    refute "send_terminal_message" in names
    refute "send_terminal_keys" in names
    refute "terminal_upload_attachment" in names

    assert {:error, message} =
             TerminalTools.call("send_terminal_message", %{
               "session" => session.id,
               "text" => "pwd"
             })

    assert message =~ "control is disabled"
  end

  test "list, send, wait and read round-trip through a visible short reference", %{
    session: session
  } do
    assert {:ok, sessions} = TerminalTools.call("list_terminal_sessions", %{})
    listed = Enum.find(sessions, &(&1.id == to_string(session.id)))
    assert listed.ref == TerminalTools.reference(session.id)
    assert listed.name == "mcp-test"

    assert {:ok, sent} =
             TerminalTools.call("send_terminal_message", %{
               "session" => listed.ref,
               "text" => "echo mcp-terminal-roundtrip",
               "submit" => true
             })

    assert sent.seq >= listed.seq

    assert {:ok, waited} =
             TerminalTools.call("wait_terminal", %{
               "session" => listed.ref,
               "after_seq" => sent.seq,
               "timeout_seconds" => 5,
               "lines" => 50
             })

    assert waited.reason in ["output", "match"]
    assert waited.seq > sent.seq
    assert waited.output =~ "mcp-terminal-roundtrip"

    assert {:ok, read} =
             TerminalTools.call("read_terminal", %{
               "session" => listed.ref,
               "lines" => 50
             })

    assert read.sessionId == to_string(session.id)
    assert read.output =~ "mcp-terminal-roundtrip"
    refute read.output =~ "\e["
    assert read.styleAware
    assert is_map(read.inputModes)
    assert is_list(read.highlightedRanges)
  end

  test "TUI snapshots expose choices and key sequences support cursor mode plus shortcuts",
       %{
         session: session
       } do
    result_path =
      Path.join(System.tmp_dir!(), "dala-tui-key-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(result_path) end)

    command =
      "printf '\\033[?1049h\\033[?1h\\033[7;1mSelected option\\033[0m'; " <>
        "IFS= read -rsN 4 key; printf '%s' \"$key\" | od -An -tx1 > #{result_path}; " <>
        "printf '\\033[?1049l'"

    Server.input(session.id, command <> "\r")

    assert eventually(fn ->
             case TerminalTools.call("read_terminal", %{"session" => session.id, "lines" => 20}) do
               {:ok, snapshot} ->
                 snapshot.mode == "alternate" and
                   snapshot.inputModes["applicationCursor"] == true and
                   Enum.any?(snapshot.highlightedRanges, &(&1["text"] == "Selected option"))

               _ ->
                 false
             end
           end)

    assert {:ok, sent} =
             TerminalTools.call("send_terminal_keys", %{
               "session" => session.id,
               "keys" => ["DOWN", "CHAR:y"]
             })

    assert sent.applicationCursor
    assert sent.keyCount == 2
    assert eventually(fn -> File.exists?(result_path) end)

    assert File.read!(result_path) |> String.replace(~r/\s+/, " ") |> String.trim() ==
             "1b 4f 42 79"
  end

  test "upload stores a private regular file and returns a sendable path" do
    body = "image-ish-content"

    assert {:ok, uploaded} =
             TerminalTools.call("terminal_upload_attachment", %{
               "name" => "screen shot.png",
               "mime_type" => "image/png",
               "content_base64" => Base.encode64(body)
             })

    assert File.read!(uploaded.path) == body
    assert uploaded.name == "screen_shot.png"
    assert uploaded.size == byte_size(body)
    assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(uploaded.path)
    assert Bitwise.band(mode, 0o077) == 0

    assert {:ok, %File.Stat{type: :directory, mode: root_mode}} =
             uploaded.path |> Path.dirname() |> Path.dirname() |> File.lstat()

    assert Bitwise.band(root_mode, 0o077) == 0

    on_exit(fn -> File.rm_rf(Path.dirname(uploaded.path)) end)
  end

  test "upload tool advertises the 64 MB decoded attachment limit" do
    tool =
      %{read: true, control: true}
      |> TerminalTools.tools()
      |> Enum.find(&(&1["name"] == "terminal_upload_attachment"))

    assert tool["description"] =~ "64 MB"
    assert tool["inputSchema"]["properties"]["content_base64"]["maxLength"] >= 89_478_488
  end

  test "terminal schemas explain TUI style fields and printable shortcut keys" do
    tools = TerminalTools.tools(%{read: true, control: true})
    read = Enum.find(tools, &(&1["name"] == "read_terminal"))
    keys = Enum.find(tools, &(&1["name"] == "send_terminal_keys"))

    assert read["description"] =~ "highlightedRanges"
    assert read["description"] =~ "inputModes"
    assert keys["description"] =~ "CHAR:y"

    [named, character] = keys["inputSchema"]["properties"]["keys"]["items"]["oneOf"]
    assert "DOWN" in named["enum"]
    assert character["pattern"] == "^CHAR:[!-~]$"
  end

  test "duplicate names are rejected as ambiguous selectors", %{session: session} do
    other =
      Dala.Terminal.create_session!(%{
        shell: "/bin/bash",
        name: session.name,
        cwd: System.tmp_dir!()
      })

    on_exit(fn ->
      Server.shutdown_and_wait(other.id)
      id = to_string(other.id)
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
    end)

    assert {:error, message} = TerminalTools.call("read_terminal", %{"session" => session.name})
    assert message =~ "ambiguous"
    assert message =~ TerminalTools.reference(session.id)
    assert message =~ TerminalTools.reference(other.id)
  end

  defp eventually(fun, attempts \\ 80) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end
end
