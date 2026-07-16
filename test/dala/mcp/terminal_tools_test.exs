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

    assert {:error, message} = TerminalTools.call("read_terminal", %{"session" => session.id})
    assert message =~ "read access is disabled"

    Dala.Settings.Mcp.set_terminal_access(true, false)
    names = Registry.tools() |> Enum.map(& &1["name"])
    assert "list_terminal_sessions" in names
    assert "read_terminal" in names
    assert "wait_terminal" in names
    refute "send_terminal_message" in names
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
end
