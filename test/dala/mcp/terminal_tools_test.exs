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
        shell: Dala.TerminalCase.shell(),
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
               "match" => "mcp-terminal-roundtrip",
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
    result_target = result_path |> Dala.TerminalCase.shell_path() |> Dala.ShellPort.escape()

    command =
      "printf '\\033[?1049h\\033[?1h\\033[7;1mSelected option\\033[0m'; " <>
        "IFS= read -rsN 4 key; printf '%s' \"$key\" | od -An -tx1 > #{result_target}; " <>
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
    assert eventually(fn -> file_hex(result_path) == "1b 4f 42 79" end)
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

    assert {:ok, %File.Stat{type: :directory, mode: root_mode}} =
             uploaded.path |> Path.dirname() |> Path.dirname() |> File.lstat()

    unless Dala.Platform.windows?() do
      assert Bitwise.band(mode, 0o077) == 0
      assert Bitwise.band(root_mode, 0o077) == 0
    end

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

  test "Ctrl+letter prefixes reach the PTY: the zellij detach chord", %{session: session} do
    result_path =
      Path.join(System.tmp_dir!(), "dala-ctrl-key-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(result_path) end)
    result_target = result_path |> Dala.TerminalCase.shell_path() |> Dala.ShellPort.escape()

    # Read the two raw bytes the chord should produce and dump them as hex.
    Server.input(
      session.id,
      "printf 'CTRL-READY\\n'; IFS= read -rsN 2 chord; " <>
        "printf '%s' \"$chord\" | od -An -tx1 > #{result_target}\r"
    )

    assert eventually(fn ->
             terminal_contains?(session.id, "CTRL-READY")
           end)

    # This is the call that used to fail with "unsupported terminal key: CTRL_O".
    assert {:ok, sent} =
             TerminalTools.call("send_terminal_keys", %{
               "session" => session.id,
               "keys" => ["CTRL_O", "CHAR:d"]
             })

    assert sent.keyCount == 2
    assert eventually(fn -> file_hex(result_path) == "0f 64" end)
  end

  test "a non-ASCII key and a non-letter Ctrl chord reach the PTY", %{session: session} do
    result_path =
      Path.join(System.tmp_dir!(), "dala-utf8-key-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(result_path) end)
    result_target = result_path |> Dala.TerminalCase.shell_path() |> Dala.ShellPort.escape()

    # Read until Enter, not a byte/character count: bash's `read -N` counts
    # characters, so a UTF-8 key would make a byte count wait forever.
    Server.input(
      session.id,
      "printf 'UTF8-READY\\n'; IFS= read -rs keys; " <>
        "printf '%s' \"$keys\" | od -An -tx1 > #{result_target}\r"
    )

    assert eventually(fn ->
             terminal_contains?(session.id, "UTF8-READY")
           end)

    assert {:ok, sent} =
             TerminalTools.call("send_terminal_keys", %{
               "session" => session.id,
               "keys" => ["CHAR:好", "CTRL_UNDERSCORE", "ENTER"]
             })

    assert sent.keyCount == 3

    assert eventually(fn ->
             file_hex(result_path) == "e5 a5 bd 1f"
           end)
  end

  test "terminal schemas explain TUI style fields and printable shortcut keys" do
    tools = TerminalTools.tools(%{read: true, control: true})
    read = Enum.find(tools, &(&1["name"] == "read_terminal"))
    keys = Enum.find(tools, &(&1["name"] == "send_terminal_keys"))

    assert read["description"] =~ "highlightedRanges"
    assert read["description"] =~ "inputModes"
    assert keys["description"] =~ "CHAR:y"

    [named, control, alt, character] =
      keys["inputSchema"]["properties"]["keys"]["items"]["oneOf"]

    assert "DOWN" in named["enum"]
    # The keys a TUI actually needs beyond letters and arrows.
    for key <- ~w(BACKSPACE DELETE F1 F12 ALT_ENTER SHIFT_UP CTRL_RIGHT ALT_LEFT) do
      assert key in named["enum"], "#{key} is not advertised"
    end

    assert alt["pattern"] == "^ALT:[!-~]$"
    assert alt["description"] =~ "one write"
    # The Ctrl+letter range is matched by pattern, not enumerated: an agent
    # needs zellij's CTRL_O and tmux's CTRL_B as much as CTRL_C.
    assert control["pattern"] == "^CTRL_[A-Z]$"
    assert control["description"] =~ "CTRL_O"
    refute Enum.any?(named["enum"], &Regex.match?(~r/^CTRL_[A-Z]$/, &1))
    assert character["pattern"] == "^CHAR:[^\\u0000-\\u001f\\u007f]{1,8}$"
    assert character["description"] =~ "any script"
    # The non-letter Ctrl chords are named, so an agent can find them.
    for key <- ~w(CTRL_SPACE CTRL_BACKSLASH CTRL_UNDERSCORE) do
      assert key in named["enum"], "#{key} is not advertised"
    end
  end

  test "duplicate names are rejected as ambiguous selectors", %{session: session} do
    other =
      Dala.Terminal.create_session!(%{
        shell: Dala.TerminalCase.shell(),
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

  defp terminal_contains?(session_id, text) do
    case TerminalTools.call("read_terminal", %{"session" => session_id}) do
      {:ok, snapshot} -> String.contains?(snapshot.output, text)
      _ -> false
    end
  end

  defp file_hex(path) do
    if File.regular?(path) do
      path |> File.read!() |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end
end
