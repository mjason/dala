defmodule Dala.Terminal.AgentEventTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.AgentEvent

  @sep <<0x1F>>

  describe "parse_agent_event/1 — warp://cli-agent (OSC 777 structured form)" do
    test "decodes the plugin JSON payload into the broadcast shape" do
      body =
        Jason.encode!(%{
          "agent" => "claude",
          "event" => "tool_use",
          "project" => "dala",
          "summary" => "Running a command",
          "query" => "fix the bug",
          "response" => "on it",
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
        })

      assert AgentEvent.parse_agent_event("warp://cli-agent" <> @sep <> body) == %{
               agent: "claude",
               event: "tool_use",
               project: "dala",
               summary: "Running a command",
               query: "fix the bug",
               response: "on it",
               toolName: "Bash",
               toolInput: "mix test"
             }
    end

    test "a missing agent falls back to unknown" do
      body = Jason.encode!(%{"event" => "stop"})

      assert %{agent: "unknown", event: "stop"} =
               AgentEvent.parse_agent_event("warp://cli-agent" <> @sep <> body)
    end

    test "invalid JSON or a payload without event is unparsed" do
      assert AgentEvent.parse_agent_event("warp://cli-agent" <> @sep <> "not json") == nil
      assert AgentEvent.parse_agent_event("warp://cli-agent" <> @sep <> ~s({"agent":"x"})) == nil
    end
  end

  describe "parse_agent_event/1 — OSC 9 form" do
    test "becomes a plain notify with the body as summary" do
      assert AgentEvent.parse_agent_event("osc9" <> @sep <> "Build finished") == %{
               agent: "unknown",
               event: "notify",
               summary: "Build finished",
               project: nil,
               query: nil,
               response: nil,
               toolName: nil,
               toolInput: nil
             }
    end
  end

  describe "parse_agent_event/1 — generic OSC 777 fallback" do
    test "title and body collapse into the summary" do
      assert %{agent: "unknown", event: "notify", summary: "My App: done"} =
               AgentEvent.parse_agent_event("My App" <> @sep <> "done")
    end

    test "a frame without the separator is unparsed" do
      assert AgentEvent.parse_agent_event("no separator here") == nil
    end
  end

  describe "tool_preview/1" do
    test "table: known input shapes and fallbacks" do
      cases = [
        {%{"command" => "ls -la"}, "ls -la"},
        {%{"file_path" => "/tmp/a.ex"}, "/tmp/a.ex"},
        {%{"filePath" => "/tmp/b.ex"}, "/tmp/b.ex"},
        # non-binary values and unknown shapes yield nil
        {%{"command" => 42}, nil},
        {%{"other" => "x"}, nil},
        {"just a string", nil},
        {nil, nil}
      ]

      for {input, expected} <- cases do
        assert AgentEvent.tool_preview(input) == expected,
               "tool_preview(#{inspect(input)}) expected #{inspect(expected)}"
      end
    end
  end

  describe "classify_app/1" do
    test "table: known agents, shell and unknown" do
      cases = [
        {nil, "shell"},
        {"claude --dangerously-skip-permissions", "claude"},
        {"node /usr/bin/OpenCode", "opencode"},
        {"codex exec", "codex"},
        {"gemini", "gemini"},
        {"gh copilot suggest", "copilot"},
        {"vim notes.md", "unknown"},
        {"", "unknown"}
      ]

      for {cmdline, expected} <- cases do
        assert AgentEvent.classify_app(cmdline) == expected,
               "classify_app(#{inspect(cmdline)}) expected #{expected}"
      end
    end
  end
end
