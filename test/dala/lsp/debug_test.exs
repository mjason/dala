defmodule Dala.Lsp.DebugTest do
  # The registry ETS table is app-global but rows are keyed by unique ids,
  # so tests only ever look at their own entries.
  use ExUnit.Case, async: true

  alias Dala.Lsp.Debug

  defp entry(id), do: Enum.find(Debug.snapshot(), &(&1.id == id))

  defp diagnostics_message(diags, uri \\ "file:///tmp/a.ex") do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => %{"uri" => uri, "diagnostics" => diags}
    })
  end

  describe "register/1 and snapshot/0" do
    test "a fresh bridge starts running with zeroed counters" do
      id = Debug.register(%{server: "pyright"})

      assert %{
               server: "pyright",
               status: "running",
               exit_status: nil,
               in_count: 0,
               out_count: 0,
               recent: [],
               diagnostics: nil
             } = entry(id)
    end

    test "ids are unique and increasing" do
      a = Debug.register(%{})
      b = Debug.register(%{})
      assert b > a
    end
  end

  describe "record/3 traffic accounting" do
    test "counts directions separately and lists recent messages oldest-first" do
      id = Debug.register(%{})

      Debug.record(id, :in, ~s({"method":"initialize"}))
      Debug.record(id, :out, ~s({"result":{}}))
      Debug.record(id, :in, ~s({"method":"shutdown"}))

      assert %{in_count: 2, out_count: 1, recent: recent} = entry(id)

      assert [
               %{dir: :in, preview: ~s({"method":"initialize"})},
               %{dir: :out, preview: ~s({"result":{}})},
               %{dir: :in, preview: ~s({"method":"shutdown"})}
             ] = recent
    end

    test "previews are truncated to 300 bytes without splitting UTF-8" do
      id = Debug.register(%{})
      # byte 300 falls inside the 3-byte "好" — the torn char must be scrubbed
      Debug.record(id, :in, String.duplicate("a", 299) <> "好这里还有更多")

      assert %{recent: [%{preview: preview}]} = entry(id)
      assert preview == String.duplicate("a", 299)
      assert String.valid?(preview)
    end

    test "invalid UTF-8 in the message is scrubbed from the preview" do
      id = Debug.register(%{})
      Debug.record(id, :in, "hello " <> <<0xFF, 0xFE>> <> "world")

      assert %{recent: [%{preview: preview}]} = entry(id)
      assert String.valid?(preview)
      assert preview == "hello world"
    end

    test "recording against an unknown id is a no-op" do
      assert Debug.record(-1, :in, "whatever") == :ok
    end
  end

  describe "record/3 diagnostics extraction" do
    test "an outgoing publishDiagnostics snapshot captures uri, count and items" do
      id = Debug.register(%{})

      message =
        diagnostics_message([
          %{
            "message" => "undefined variable x",
            "severity" => 1,
            "range" => %{"start" => %{"line" => 7, "character" => 2}}
          }
        ])

      Debug.record(id, :out, message)

      assert %{
               diagnostics: %{
                 uri: "file:///tmp/a.ex",
                 count: 1,
                 items: [%{message: "undefined variable x", severity: 1, line: 7}]
               }
             } = entry(id)
    end

    test "items are capped at 20 while count reflects the full list" do
      id = Debug.register(%{})
      diags = for i <- 1..25, do: %{"message" => "d#{i}", "severity" => 2}

      Debug.record(id, :out, diagnostics_message(diags))

      assert %{diagnostics: %{count: 25, items: items}} = entry(id)
      assert length(items) == 20
    end

    test "long diagnostic messages are sliced to 200 chars" do
      id = Debug.register(%{})
      Debug.record(id, :out, diagnostics_message([%{"message" => String.duplicate("m", 500)}]))

      assert %{diagnostics: %{items: [%{message: message}]}} = entry(id)
      assert String.length(message) == 200
    end

    test "incoming messages never set diagnostics, and malformed ones keep the last snapshot" do
      id = Debug.register(%{})

      Debug.record(id, :in, diagnostics_message([%{"message" => "ignored"}]))
      assert %{diagnostics: nil} = entry(id)

      Debug.record(id, :out, diagnostics_message([%{"message" => "kept"}]))
      Debug.record(id, :out, "not json but mentions publishDiagnostics")

      assert %{diagnostics: %{items: [%{message: "kept"}]}} = entry(id)
    end
  end

  describe "exited/2" do
    test "marks the bridge exited with its status, keeping the row" do
      id = Debug.register(%{})
      Debug.exited(id, 137)

      assert %{status: "exited", exit_status: 137} = entry(id)
    end

    test "an unknown id is a no-op" do
      assert Debug.exited(-1, 0) == :ok
    end
  end
end
