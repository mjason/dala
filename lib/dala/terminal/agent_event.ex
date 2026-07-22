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

  @doc "Classifies the foreground program from a Windows shell process tree."
  def foreground_from_processes([]), do: %{app: "shell", cmdline: ""}

  def foreground_from_processes(processes) when is_list(processes) do
    parents =
      Map.new(processes, fn process ->
        {process["pid"], process["parent_pid"]}
      end)

    ranked =
      Enum.map(processes, fn process ->
        cmdline = process_cmdline(process)

        %{
          app: classify_process(process),
          cmdline: cmdline,
          depth: process_depth(process["pid"], parents, MapSet.new())
        }
      end)

    selected =
      ranked
      |> Enum.filter(&(&1.app != "unknown"))
      |> Enum.max_by(& &1.depth, fn -> Enum.max_by(ranked, & &1.depth) end)

    %{app: selected.app, cmdline: selected.cmdline}
  end

  defp classify_process(process) do
    executable = process |> Map.get("executable", "") |> basename()
    argv = Map.get(process, "argv", [])
    command = Enum.join([Map.get(process, "executable", "") | argv], " ")
    normalized = command |> String.replace("\\", "/") |> String.downcase()

    cond do
      executable == "claude" or
        normalized =~ ~r{(?:^|[\s/"'])claude(?:\.cmd|\.exe)?(?:$|[\s"'])} or
          String.contains?(normalized, "/@anthropic-ai/claude-code/") ->
        "claude"

      executable == "codex" or
        normalized =~ ~r{(?:^|[\s/"'])codex(?:\.cmd|\.exe)?(?:$|[\s"'])} or
          String.contains?(normalized, "/@openai/codex/") ->
        "codex"

      executable == "opencode" or
        normalized =~ ~r{(?:^|[\s/"'])opencode(?:\.cmd|\.exe)?(?:$|[\s"'])} or
          String.contains?(normalized, "/opencode-ai/") ->
        "opencode"

      executable == "gemini" or
        normalized =~ ~r{(?:^|[\s/"'])gemini(?:\.cmd|\.exe)?(?:$|[\s"'])} or
          String.contains?(normalized, "/@google/gemini-cli/") ->
        "gemini"

      true ->
        "unknown"
    end
  end

  defp process_cmdline(process) do
    case Map.get(process, "argv", []) do
      [] -> Map.get(process, "executable", "")
      argv -> Enum.join(argv, " ")
    end
  end

  defp process_depth(nil, _parents, _seen), do: 0

  defp process_depth(pid, parents, seen) do
    if MapSet.member?(seen, pid) do
      0
    else
      case Map.get(parents, pid) do
        parent when is_integer(parent) and is_map_key(parents, parent) ->
          1 + process_depth(parent, parents, MapSet.put(seen, pid))

        _root_or_missing ->
          0
      end
    end
  end

  defp basename(path) do
    path
    |> String.replace("\\", "/")
    |> Path.basename()
    |> String.downcase()
    |> String.replace_suffix(".exe", "")
    |> String.replace_suffix(".cmd", "")
    |> String.replace_suffix(".bat", "")
  end
end
