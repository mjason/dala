defmodule Dala.Terminal.AgentEvent do
  @moduledoc """
  OSC agent-notification parsing for `Dala.Terminal.Server`.

  The holder forwards OSC notifications as `title \\x1f body` frames.
  Structured events (title `warp://cli-agent`, Warp's open protocol) carry a
  JSON payload from the agent's plugin hooks; OSC 9 (title `"osc9"`) and
  generic OSC 777 notifications become plain "notify" events.
  """

  @doc """
  Parses one holder agent frame into the `agent_event` payload broadcast on
  the sessions lobby, or `nil` when the frame is not understood.
  """
  def parse_agent_event(payload) do
    case :binary.split(payload, <<0x1F>>) do
      ["warp://cli-agent", body] ->
        case Jason.decode(body) do
          {:ok, %{"event" => event} = raw} ->
            %{
              agent: raw["agent"] || "unknown",
              event: event,
              project: raw["project"],
              summary: raw["summary"],
              query: raw["query"],
              response: raw["response"],
              toolName: raw["tool_name"],
              toolInput: tool_preview(raw["tool_input"])
            }

          _ ->
            nil
        end

      ["osc9", body] ->
        %{
          agent: "unknown",
          event: "notify",
          summary: body,
          project: nil,
          query: nil,
          response: nil,
          toolName: nil,
          toolInput: nil
        }

      [title, body] ->
        %{
          agent: "unknown",
          event: "notify",
          summary: "#{title}: #{body}",
          project: nil,
          query: nil,
          response: nil,
          toolName: nil,
          toolInput: nil
        }

      _ ->
        nil
    end
  end

  @doc "One-line preview of a tool invocation's input, or nil."
  def tool_preview(%{"command" => command}) when is_binary(command), do: command
  def tool_preview(%{"file_path" => path}) when is_binary(path), do: path
  def tool_preview(%{"filePath" => path}) when is_binary(path), do: path
  def tool_preview(_), do: nil

  @doc """
  Classifies a foreground command line as a known CLI agent, `"shell"` (no
  foreground program) or `"unknown"`. Warp's rich-input strategies are per
  agent; the client picks one based on this.
  """
  def classify_app(nil), do: "shell"

  def classify_app(cmdline) do
    down = String.downcase(cmdline)

    cond do
      down =~ "claude" -> "claude"
      down =~ "opencode" -> "opencode"
      down =~ "codex" -> "codex"
      down =~ "gemini" -> "gemini"
      down =~ "copilot" -> "copilot"
      true -> "unknown"
    end
  end
end
