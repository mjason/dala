defmodule Dala.Mcp.TerminalTools do
  @moduledoc false

  @read_tools ~w(list_terminal_sessions read_terminal wait_terminal)
  @control_tools ~w(send_terminal_message terminal_upload_attachment)
  @all_tools @read_tools ++ @control_tools

  def tool_names, do: @all_tools

  def tools(%{read: read?, control: control?}) do
    []
    |> maybe_add(read?, list_tool())
    |> maybe_add(read?, read_tool())
    |> maybe_add(read?, wait_tool())
    |> maybe_add(control?, send_tool())
    |> maybe_add(control?, upload_tool())
  end

  def call(name, arguments) when name in @all_tools do
    access = Dala.Settings.Mcp.terminal_access()

    cond do
      name in @control_tools and not access.control ->
        {:error, "MCP terminal control is disabled in dala Settings"}

      name in @read_tools and not access.read ->
        {:error, "MCP terminal read access is disabled in dala Settings"}

      true ->
        execute(name, normalize(arguments))
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def call(_name, _arguments), do: {:error, :unknown_tool}

  def reference(id) do
    id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(0, 6)
    |> String.upcase()
    |> then(&("#" <> &1))
  end

  defp execute("list_terminal_sessions", _arguments) do
    sessions = Dala.Terminal.list_sessions!()
    {:ok, Enum.map(sessions, &session_summary/1)}
  end

  defp execute("read_terminal", arguments) do
    with {:ok, session} <- resolve_session(arguments["session"]),
         {:ok, snapshot} <-
           Dala.Terminal.Server.snapshot(session.id,
             lines: bounded_lines(arguments["lines"]),
             max_bytes: 64 * 1024
           ) do
      {:ok, snapshot_result(session, snapshot)}
    end
  end

  defp execute("send_terminal_message", arguments) do
    with {:ok, session} <- resolve_session(arguments["session"]),
         {:ok, %{app: app}} <- Dala.Terminal.Server.foreground_app(session.id),
         :ok <- validate_text(arguments["text"]),
         {:ok, submit} <- validate_submit(Map.get(arguments, "submit", true)),
         {:ok, frames} <-
           Dala.Terminal.Input.frames(
             app,
             arguments["text"] || "",
             arguments["attachments"] || [],
             submit,
             arguments["key"]
           ),
         {:ok, seq} <- Dala.Terminal.Server.send_sequence(session.id, frames) do
      {:ok,
       %{
         sessionId: to_string(session.id),
         ref: reference(session.id),
         name: session.name,
         app: app,
         seq: seq,
         queued: true
       }}
    end
  end

  defp execute("wait_terminal", arguments) do
    with {:ok, session} <- resolve_session(arguments["session"]),
         {:ok, after_seq} <- validate_after_seq(arguments["after_seq"]),
         {:ok, result} <-
           Dala.Terminal.Server.wait(session.id, after_seq,
             timeout: bounded_timeout(arguments["timeout_seconds"]),
             events: normalize_events(arguments["events"]),
             match: normalize_match(arguments["match"])
           ) do
      if result.reason == "timeout" do
        {:ok, Map.merge(session_identity(session), result)}
      else
        session = reload_session(session)

        case Dala.Terminal.Server.snapshot(session.id,
               lines: bounded_lines(arguments["lines"]),
               max_bytes: 64 * 1024
             ) do
          {:ok, snapshot} ->
            {:ok,
             session
             |> snapshot_result(snapshot)
             |> Map.merge(result)}

          {:error, _message} ->
            {:ok, Map.merge(session_identity(session), result)}
        end
      end
    end
  end

  defp execute("terminal_upload_attachment", arguments) do
    Dala.Terminal.Attachments.upload(
      arguments["name"],
      arguments["mime_type"],
      arguments["content_base64"]
    )
  end

  defp session_summary(session) do
    seq =
      case Dala.Terminal.Server.current_seq(session.id) do
        {:ok, value} -> value
        {:error, _message} -> 0
      end

    %{
      id: to_string(session.id),
      ref: reference(session.id),
      name: session.name,
      shell: session.shell,
      cwd: session.cwd,
      status: to_string(session.status),
      exitCode: session.exit_code,
      seq: seq,
      insertedAt: session.inserted_at
    }
  end

  defp session_identity(session) do
    %{
      sessionId: to_string(session.id),
      ref: reference(session.id),
      name: session.name,
      status: to_string(session.status)
    }
  end

  defp snapshot_result(session, snapshot) do
    lines = snapshot["lines"] || []

    session
    |> session_identity()
    |> Map.merge(%{
      seq: snapshot["seq"] || 0,
      mode: snapshot["mode"] || "normal",
      output: Enum.join(lines, "\n"),
      cachedLineCount: snapshot["cachedLineCount"] || length(lines),
      truncated: snapshot["truncated"] == true,
      rows: snapshot["rows"],
      columns: snapshot["columns"],
      cursor: snapshot["cursor"]
    })
  end

  defp resolve_session(selector) when is_binary(selector) do
    selector = String.trim(selector)
    sessions = Dala.Terminal.list_sessions!()

    cond do
      selector == "" ->
        {:error, "session is required"}

      match?({:ok, _}, Ecto.UUID.cast(selector)) ->
        case Dala.Terminal.get_session(selector) do
          {:ok, session} -> {:ok, session}
          {:error, _error} -> {:error, "terminal session not found: #{selector}"}
        end

      true ->
        resolve_human_selector(sessions, selector)
    end
  end

  defp resolve_session(_selector), do: {:error, "session is required"}

  defp resolve_human_selector(sessions, selector) do
    compact = selector |> String.trim_leading("#") |> String.replace("-", "") |> String.downcase()

    ref_matches =
      if String.length(compact) >= 6 and compact =~ ~r/^[0-9a-f]+$/ do
        Enum.filter(sessions, fn session ->
          session.id
          |> to_string()
          |> String.replace("-", "")
          |> String.downcase()
          |> String.starts_with?(compact)
        end)
      else
        []
      end

    matches =
      if ref_matches == [] do
        Enum.filter(sessions, &(&1.name == selector))
      else
        ref_matches
      end

    case matches do
      [session] -> {:ok, session}
      [] -> {:error, "terminal session not found: #{selector}"}
      many -> {:error, ambiguous_message(selector, many)}
    end
  end

  defp ambiguous_message(selector, sessions) do
    candidates =
      Enum.map_join(sessions, ", ", fn session ->
        "#{session.name} (#{reference(session.id)}, #{session.id})"
      end)

    "terminal session selector is ambiguous: #{selector}; candidates: #{candidates}"
  end

  defp reload_session(session) do
    case Dala.Terminal.get_session(session.id) do
      {:ok, reloaded} -> reloaded
      {:error, _error} -> session
    end
  end

  defp validate_text(nil), do: :ok
  defp validate_text(text) when is_binary(text) and byte_size(text) <= 65_536, do: :ok
  defp validate_text(_text), do: {:error, "text must be at most 65536 bytes"}

  defp validate_submit(value) when is_boolean(value), do: {:ok, value}
  defp validate_submit(_value), do: {:error, "submit must be a boolean"}

  defp validate_after_seq(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_after_seq(_value), do: {:error, "after_seq must be a non-negative integer"}

  defp bounded_lines(nil), do: 200
  defp bounded_lines(0), do: 0
  defp bounded_lines(value) when is_integer(value), do: value |> max(1) |> min(50_000)
  defp bounded_lines(_value), do: 200

  defp bounded_timeout(nil), do: 25_000

  defp bounded_timeout(value) when is_integer(value),
    do: value |> max(1) |> min(25) |> Kernel.*(1_000)

  defp bounded_timeout(_value), do: 25_000

  defp normalize_match(nil), do: nil
  defp normalize_match(""), do: nil
  defp normalize_match(value) when is_binary(value), do: String.slice(value, 0, 512)
  defp normalize_match(_value), do: nil

  defp normalize_events(values) when is_list(values) do
    allowed = ~w(output idle question permission stop exit)
    selected = Enum.filter(values, &(&1 in allowed))
    if selected == [], do: allowed, else: selected
  end

  defp normalize_events(_values), do: ~w(output idle question permission stop exit)
  defp normalize(arguments) when is_map(arguments), do: arguments
  defp normalize(_arguments), do: %{}
  defp maybe_add(tools, true, tool), do: tools ++ [tool]
  defp maybe_add(tools, false, _tool), do: tools

  defp list_tool do
    tool(
      "list_terminal_sessions",
      "List every dala terminal session with its canonical UUID, visible short reference, name, cwd, status and current event sequence.",
      %{}
    )
  end

  defp read_tool do
    tool(
      "read_terminal",
      "Read a bounded plain-text snapshot of a terminal's server-side grid and scrollback. Wrapped rows are joined into logical lines; alternate-screen TUIs return their current screen.",
      %{
        "session" => selector_schema(),
        "lines" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 50_000,
          "description" =>
            "Recent logical lines to return (default 200; 0 means all that fit in the bounded response)."
        }
      },
      ["session"]
    )
  end

  defp wait_tool do
    tool(
      "wait_terminal",
      "Wait up to 25 seconds for output, an agent idle/question/permission/stop event, exit, or an optional plain-text substring, then return a fresh terminal snapshot. Continue watching by passing the returned seq as after_seq.",
      %{
        "session" => selector_schema(),
        "after_seq" => %{"type" => "integer", "minimum" => 0},
        "timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 25},
        "lines" => %{"type" => "integer", "minimum" => 0, "maximum" => 50_000},
        "match" => %{"type" => "string", "maxLength" => 512},
        "events" => %{
          "type" => "array",
          "items" => %{
            "type" => "string",
            "enum" => ~w(output idle question permission stop exit)
          },
          "uniqueItems" => true
        }
      },
      ["session", "after_seq"]
    )
  end

  defp send_tool do
    tool(
      "send_terminal_message",
      "Send text, attachment paths, Enter, or one supported control key to a running terminal. Delivery is serialized per session and uses the foreground CLI agent's paste timing. Returns a baseline seq for wait_terminal.",
      %{
        "session" => selector_schema(),
        "text" => %{"type" => "string", "maxLength" => 65_536},
        "attachments" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "maxItems" => 20,
          "description" =>
            "Absolute paths returned by terminal_upload_attachment or existing regular server files."
        },
        "submit" => %{"type" => "boolean", "default" => true},
        "key" => %{
          "type" => "string",
          "enum" => ~w(ENTER ESC TAB UP DOWN LEFT RIGHT CTRL_C CTRL_D CTRL_Z)
        }
      },
      ["session"]
    )
  end

  defp upload_tool do
    max_bytes = Dala.FileLimits.mcp_attachment_bytes()
    max_base64_length = div(max_bytes + 2, 3) * 4

    tool(
      "terminal_upload_attachment",
      "Upload one file or image into dala's private 24-hour attachment store. Use the returned absolute path in send_terminal_message.attachments. Maximum decoded size: #{Dala.FileLimits.format(max_bytes)}.",
      %{
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
        "mime_type" => %{"type" => "string", "maxLength" => 255},
        "content_base64" => %{"type" => "string", "maxLength" => max_base64_length}
      },
      ["name", "content_base64"]
    )
  end

  defp selector_schema do
    %{
      "type" => "string",
      "description" =>
        "Full session UUID, visible #short-reference, or an exact unique session name."
    }
  end

  defp tool(name, description, properties, required \\ []) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => properties,
        "required" => required
      }
    }
  end
end
