defmodule DalaWeb.McpControllerTest do
  # async: false — the MCP config is a single instance-wide DB singleton row.
  use DalaWeb.ConnCase, async: false

  @token "test-mcp-token-8f3c2a"

  setup do
    # Enable the endpoint and pin a KNOWN token so `mcp_post` can present it.
    # Gate cases below re-seed to exercise the disabled/blank-token paths.
    seed_mcp(true, @token)
    :ok
  end

  # Provision the singleton, then force a known {enabled, token} through the
  # resource's internal :write action (never exposed over rpc/MCP).
  defp seed_mcp(enabled, token) do
    _ = Dala.Settings.Mcp.config()

    Dala.Settings.Mcp
    |> Ash.read!(authorize?: false)
    |> hd()
    |> Ash.Changeset.for_update(:write, %{enabled: enabled, token: token}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  # Every request starts from a fresh conn (avoids ConnTest header-recycling)
  # but runs in the test process, so the SQL sandbox is shared across calls.
  defp mcp_post(body, opts \\ []) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn = put_req_header(build_conn(), "content-type", "application/json")

    conn =
      case Keyword.get(opts, :auth, :default) do
        :default -> put_req_header(conn, "authorization", "Bearer #{@token}")
        :none -> conn
        header when is_binary(header) -> put_req_header(conn, "authorization", header)
      end

    post(conn, "/mcp", raw)
  end

  defp rpc(method, id, params \\ %{}) do
    %{jsonrpc: "2.0", id: id, method: method, params: params}
  end

  defp call_tool(name, arguments) do
    body =
      rpc("tools/call", System.unique_integer([:positive]), %{name: name, arguments: arguments})

    json_response(mcp_post(body), 200)
  end

  defp tool_content(response), do: Jason.decode!(hd(response["result"]["content"])["text"])

  describe "gate" do
    test "disabled -> 404 (endpoint invisible)" do
      seed_mcp(false, @token)
      assert mcp_post(rpc("ping", 1)).status == 404
    end

    test "enabled but empty token -> 503 fail-closed" do
      seed_mcp(true, "")
      assert mcp_post(rpc("ping", 1), auth: :none).status == 503
    end

    test "enabled but blank token -> 503 fail-closed" do
      seed_mcp(true, "   ")
      assert mcp_post(rpc("ping", 1), auth: :none).status == 503
    end

    test "missing Authorization -> 401" do
      assert mcp_post(rpc("ping", 1), auth: :none).status == 401
    end

    test "wrong token -> 401" do
      assert mcp_post(rpc("ping", 1), auth: "Bearer nope").status == 401
    end

    test "correct token -> proceeds (200)" do
      assert mcp_post(rpc("ping", 1)).status == 200
    end
  end

  describe "protocol" do
    test "initialize echoes a supported protocolVersion and reports serverInfo" do
      body =
        json_response(mcp_post(rpc("initialize", 1, %{protocolVersion: "2025-06-18"})), 200)

      assert body["jsonrpc"] == "2.0"
      assert body["id"] == 1
      assert body["result"]["protocolVersion"] == "2025-06-18"
      assert body["result"]["serverInfo"]["name"] == "dala"
      assert is_map(body["result"]["capabilities"]["tools"])
    end

    test "initialize falls back to latest for an unknown protocolVersion" do
      body =
        json_response(mcp_post(rpc("initialize", 1, %{protocolVersion: "1999-01-01"})), 200)

      assert body["result"]["protocolVersion"] == "2025-06-18"
    end

    test "notifications/initialized -> 202 with empty body" do
      conn = mcp_post(%{jsonrpc: "2.0", method: "notifications/initialized"})
      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "ping -> empty result object" do
      assert json_response(mcp_post(rpc("ping", 2)), 200)["result"] == %{}
    end
  end

  describe "errors" do
    test "unknown method -> -32601" do
      assert json_response(mcp_post(rpc("no/such", 3)), 200)["error"]["code"] == -32601
    end

    test "unknown tool -> -32602" do
      assert call_tool("does_not_exist", %{})["error"]["code"] == -32602
    end

    test "malformed jsonrpc envelope -> -32600" do
      body = json_response(mcp_post(%{id: 4, method: "ping"}), 200)
      assert body["error"]["code"] == -32600
    end

    test "unparseable JSON -> -32700" do
      body = json_response(mcp_post("{not valid json"), 200)
      assert body["error"]["code"] == -32700
    end

    test "a notifications/* method sent WITH an id -> -32601 (not left hanging)" do
      body = json_response(mcp_post(rpc("notifications/foo", 7)), 200)
      assert body["error"]["code"] == -32601
    end
  end

  describe "request body size" do
    test "unauthenticated bodies stay at 1 MB while authenticated bodies allow attachments" do
      previous = Application.get_env(:dala, :file_limits, %{})
      Application.put_env(:dala, :file_limits, %{mcp_attachment_bytes: 1_048_576})
      on_exit(fn -> Application.put_env(:dala, :file_limits, previous) end)

      assert_error_sent(413, fn ->
        mcp_post(String.duplicate("x", 1_100_000), auth: :none)
      end)

      # A valid token gets a larger, Base64-aware budget.
      assert json_response(mcp_post(String.duplicate("x", 1_100_000)), 200)["error"]["code"] ==
               -32700

      cap = Dala.FileLimits.json_request_bytes("/mcp")
      assert cap > 1_100_000
      assert_error_sent(413, fn -> mcp_post(String.duplicate("x", cap + 1)) end)
    end
  end

  describe "batching" do
    test "a batch of 2 requests returns an array of 2 responses" do
      body = json_response(mcp_post([rpc("ping", 1), rpc("ping", 2)]), 200)
      assert is_list(body)
      assert Enum.map(body, & &1["id"]) == [1, 2]
    end

    test "a batch of only notifications -> 202 empty body" do
      batch = [
        %{jsonrpc: "2.0", method: "notifications/initialized"},
        %{jsonrpc: "2.0", method: "notifications/progress"}
      ]

      conn = mcp_post(batch)
      assert conn.status == 202
      assert conn.resp_body == ""
    end
  end

  describe "tools/list" do
    test "lists every settings tool plus theme_reference, with rich theme schema" do
      body = json_response(mcp_post(rpc("tools/list", 5)), 200)
      names = Enum.map(body["result"]["tools"], & &1["name"])

      for expected <- ~w(create_theme list_themes update_theme delete_theme get_theme
                         speech_settings set_speech_settings theme_reference) do
        assert expected in names
      end

      create = Enum.find(body["result"]["tools"], &(&1["name"] == "create_theme"))
      assert map_size(create["inputSchema"]["properties"]["tokens"]["properties"]) == 39
      assert create["inputSchema"]["properties"]["base"]["enum"] == ["light", "dark"]
    end

    test "SECURITY: the MCP self-management actions are NOT exposed as tools" do
      body = json_response(mcp_post(rpc("tools/list", 6)), 200)
      names = Enum.map(body["result"]["tools"], & &1["name"])

      for forbidden <-
            ~w(mcp_settings set_mcp_enabled set_mcp_terminal_access regenerate_mcp_token) do
        refute forbidden in names,
               "#{forbidden} must never be an MCP tool (privilege escalation)"
      end
    end

    test "terminal tools appear only for the permissions granted in Settings" do
      disabled = json_response(mcp_post(rpc("tools/list", 61)), 200)
      names = Enum.map(disabled["result"]["tools"], & &1["name"])
      refute "list_terminal_sessions" in names
      refute "send_terminal_message" in names

      Dala.Settings.Mcp.set_terminal_access(true, false)
      readable = json_response(mcp_post(rpc("tools/list", 62)), 200)
      names = Enum.map(readable["result"]["tools"], & &1["name"])
      assert "list_terminal_sessions" in names
      assert "read_terminal" in names
      assert "wait_terminal" in names
      refute "send_terminal_message" in names

      Dala.Settings.Mcp.set_terminal_access(true, true)
      controlled = json_response(mcp_post(rpc("tools/list", 63)), 200)
      names = Enum.map(controlled["result"]["tools"], & &1["name"])
      assert "send_terminal_message" in names
      assert "terminal_upload_attachment" in names
    end
  end

  describe "terminal attachments" do
    test "an authenticated control-enabled call uploads one file" do
      Dala.Settings.Mcp.set_terminal_access(true, true)

      response =
        call_tool("terminal_upload_attachment", %{
          name: "evidence.txt",
          mime_type: "text/plain",
          content_base64: Base.encode64("evidence")
        })

      assert response["result"]["isError"] == false
      uploaded = tool_content(response)
      assert File.read!(uploaded["path"]) == "evidence"
      on_exit(fn -> File.rm_rf(Path.dirname(uploaded["path"])) end)
    end
  end

  describe "theme_reference" do
    test "returns the 39 grouped token keys and the built-in presets" do
      data = tool_content(call_tool("theme_reference", %{}))

      total = data["tokenKeys"] |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      assert total == 39
      assert length(data["presets"]) == 6
      assert Enum.all?(data["presets"], &(&1["base"] in ["light", "dark"]))
    end
  end

  describe "theme lifecycle" do
    test "create -> list -> get -> update -> delete a global theme" do
      name = "MCP Theme #{System.unique_integer([:positive])}"

      created =
        call_tool("create_theme", %{name: name, base: "dark", tokens: %{bg0: "#111111"}})

      assert created["result"]["isError"] == false
      theme = tool_content(created)
      assert theme["owner_id"] == Dala.Settings.Theme.global_id()
      id = theme["id"]

      listed = tool_content(call_tool("list_themes", %{}))
      assert Enum.any?(listed, &(&1["id"] == id))

      got = tool_content(call_tool("get_theme", %{id: id}))
      assert got["id"] == id

      updated = tool_content(call_tool("update_theme", %{id: id, name: name <> " v2"}))
      assert updated["name"] == name <> " v2"

      deleted = call_tool("delete_theme", %{id: id})
      assert deleted["result"]["isError"] == false

      after_delete = tool_content(call_tool("list_themes", %{}))
      refute Enum.any?(after_delete, &(&1["id"] == id))
    end

    test "update_theme MERGES tokens — a sparse edit keeps the other overrides" do
      name = "MCP Merge #{System.unique_integer([:positive])}"

      created =
        call_tool("create_theme", %{
          name: name,
          base: "dark",
          tokens: %{bg0: "#111111", fg: "#eeeeee"}
        })

      id = tool_content(created)["id"]

      # Change only bg0; the fg override must survive (merge, not replace).
      updated = tool_content(call_tool("update_theme", %{id: id, tokens: %{bg0: "#222222"}}))
      assert updated["tokens"]["bg0"] == "#222222"
      assert updated["tokens"]["fg"] == "#eeeeee"

      call_tool("delete_theme", %{id: id})
    end

    test "get_theme miss returns null content, not an error" do
      response = call_tool("get_theme", %{id: "00000000-0000-0000-0000-0000000000ff"})
      assert response["result"]["isError"] == false
      assert hd(response["result"]["content"])["text"] == "null"
    end

    test "invalid colour token is rejected as isError (the write-guard fires)" do
      response =
        call_tool("create_theme", %{
          name: "Bad #{System.unique_integer([:positive])}",
          base: "dark",
          tokens: %{bg0: "url(https://evil/x)"}
        })

      assert response["result"]["isError"] == true
      assert hd(response["result"]["content"])["text"] =~ "not a valid CSS colour"
    end
  end

  describe "speech settings never leak the api key" do
    test "set_speech_settings then speech_settings expose only api_key_set" do
      save_conn =
        mcp_post(
          rpc("tools/call", 42, %{
            name: "set_speech_settings",
            arguments: %{endpoint: "http://x", model: "whisper", api_key: "supersecretvalue"}
          })
        )

      body = json_response(save_conn, 200)
      assert body["result"]["isError"] == false
      saved = tool_content(body)
      assert saved["api_key_set"] == true
      refute Map.has_key?(saved, "api_key")

      # The raw wire response must never carry the secret itself.
      refute save_conn.resp_body =~ "supersecretvalue"

      current = tool_content(call_tool("speech_settings", %{}))
      assert current["api_key_set"] == true
      refute Map.has_key?(current, "api_key")
    end
  end
end
