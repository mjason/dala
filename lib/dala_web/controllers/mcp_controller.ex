defmodule DalaWeb.McpController do
  use DalaWeb, :controller

  @moduledoc """
  The MCP (Model Context Protocol) endpoint — a single `POST /mcp` speaking
  JSON-RPC 2.0 over Streamable HTTP. Stateless: every request is answered with
  one `application/json` body (no SSE, no session id). The gate in front of it
  is `DalaWeb.Plugs.RequireMcp`; the tools come from `Dala.Mcp.Registry` and run
  through `Dala.Mcp.Tools`.

  Batching is supported: the body may be a single JSON-RPC object or an array of
  them. Notifications (requests without an `id`) get no response element; a POST
  whose items are ALL notifications returns `202` with an empty body.
  """

  require Logger

  alias Dala.Mcp.{Registry, Tools}

  # Newest protocol we speak; we echo the client's requested version when we
  # recognise it, otherwise we answer with this one.
  @latest_protocol "2025-06-18"
  @supported_protocols ["2025-06-18", "2025-03-26", "2024-11-05"]

  def handle(conn, _params) do
    raw = Map.get(conn.private, :mcp_raw_body, "")

    case Jason.decode(raw) do
      {:ok, decoded} -> dispatch(conn, decoded)
      {:error, _reason} -> reply(conn, error_object(nil, -32700, "Parse error"))
    end
  end

  # A JSON-RPC batch (array of calls).
  defp dispatch(conn, batch) when is_list(batch) do
    case batch do
      [] ->
        reply(conn, error_object(nil, -32600, "Invalid Request"))

      items ->
        responses = Enum.flat_map(items, &responses_for/1)
        if responses == [], do: accepted(conn), else: reply(conn, responses)
    end
  end

  # A single JSON-RPC call.
  defp dispatch(conn, %{} = item) do
    case responses_for(item) do
      [] -> accepted(conn)
      [response] -> reply(conn, response)
    end
  end

  # Anything else (bare string/number/bool/null) is not a valid request.
  defp dispatch(conn, _other), do: reply(conn, error_object(nil, -32600, "Invalid Request"))

  # Returns `[]` for notifications (no response element) or `[response]` for
  # requests. Wrapped so a bug in one item never takes down a whole batch.
  defp responses_for(item) do
    handle_item(item)
  rescue
    error ->
      Logger.error("MCP internal error: #{Exception.message(error)}")
      id = if is_map(item), do: item["id"], else: nil
      [error_object(id, -32603, "Internal error")]
  end

  defp handle_item(item) when is_map(item) do
    cond do
      item["jsonrpc"] != "2.0" ->
        respond(item, error_object(item["id"], -32600, "Invalid Request"))

      not is_binary(item["method"]) ->
        respond(item, error_object(item["id"], -32600, "Invalid Request"))

      true ->
        route(item)
    end
  end

  defp handle_item(_item), do: [error_object(nil, -32600, "Invalid Request")]

  defp route(%{"method" => "notifications/" <> _} = item) do
    # MCP notifications never carry an `id`. If a client mislabels one as a
    # request (id present), answer -32601 rather than leave it hanging with no
    # response element.
    if Map.has_key?(item, "id") do
      respond(item, error_object(item["id"], -32601, "Method not found"))
    else
      []
    end
  end

  defp route(item) do
    # A JSON-RPC notification omits `id` entirely and never gets a response.
    if Map.has_key?(item, "id") do
      respond(item, method_result(item["method"], item["id"], params(item)))
    else
      []
    end
  end

  # Always emit one element for a request; `respond/2` keeps the shape uniform.
  defp respond(_item, response), do: [response]

  defp params(item) do
    case item["params"] do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  # --- methods --------------------------------------------------------------

  defp method_result("initialize", id, params), do: result_object(id, initialize(params))
  defp method_result("ping", id, _params), do: result_object(id, %{})
  defp method_result("tools/list", id, _params), do: result_object(id, %{tools: Registry.tools()})
  defp method_result("tools/call", id, params), do: tools_call(id, params)
  defp method_result(_method, id, _params), do: error_object(id, -32601, "Method not found")

  defp initialize(params) do
    requested = params["protocolVersion"]

    version =
      if is_binary(requested) and requested in @supported_protocols,
        do: requested,
        else: @latest_protocol

    %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "dala", version: to_string(Application.spec(:dala, :vsn))}
    }
  end

  defp tools_call(id, params) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    case Tools.call(name, arguments) do
      {:error, :unknown_tool} ->
        error_object(id, -32602, "Unknown tool: #{inspect(name)}")

      {:ok, clean} ->
        result_object(id, %{content: [text(Jason.encode!(clean))], isError: false})

      {:error, message} ->
        result_object(id, %{content: [text(message)], isError: true})
    end
  end

  defp text(body), do: %{type: "text", text: body}

  # --- JSON-RPC envelopes ---------------------------------------------------

  defp result_object(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  defp error_object(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  # --- HTTP responses -------------------------------------------------------

  defp reply(conn, payload), do: json(conn, payload)

  defp accepted(conn), do: send_resp(conn, 202, "")
end
