defmodule Dala.Mcp.RegistryTest do
  # Pure introspection over the Settings domain — no DB, no app-env mutation.
  use ExUnit.Case, async: true

  alias Dala.Mcp.Registry
  alias Dala.Settings.Theme.Tokens

  defp tool(name), do: Enum.find(Registry.tools(), &(&1["name"] == name))

  test "auto-derives tools plus both theme design helpers" do
    names = Enum.map(Registry.tools(), & &1["name"])

    for expected <- ~w(speech_settings set_speech_settings list_themes get_theme
                       create_theme update_theme delete_theme theme_reference preview_theme) do
      assert expected in names, "expected #{expected} in #{inspect(names)}"
    end
  end

  test "the prompt stash surfaces as MCP tools (capture ideas from anywhere)" do
    names = Enum.map(Registry.tools(), & &1["name"])

    for expected <- ~w(list_prompts stash_prompt archive_prompt restore_prompt
                       edit_prompt delete_prompt) do
      assert expected in names, "expected #{expected} in #{inspect(names)}"
    end

    schema = tool("stash_prompt")["inputSchema"]
    assert schema["properties"]["content"]["type"] == "string"
    assert "content" in schema["required"]
  end

  test "SECURITY: the Dala.Settings.Mcp self-management actions are excluded" do
    names = Enum.map(Registry.tools(), & &1["name"])

    # These are exposed over typescript_rpc for the web UI, but must NEVER
    # become MCP tools — an AI on /mcp toggling MCP or rotating its own token
    # would be privilege escalation. See Registry's @self_managed_resources.
    for forbidden <- ~w(mcp_settings set_mcp_enabled regenerate_mcp_token) do
      refute forbidden in names, "#{forbidden} must not be an MCP tool"
    end
  end

  test "create_theme inputSchema inlines all 46 token keys and a light|dark base enum" do
    schema = tool("create_theme")["inputSchema"]

    assert map_size(schema["properties"]["tokens"]["properties"]) == Tokens.count()
    assert map_size(schema["properties"]["tokens"]["properties"]) == 46
    assert schema["properties"]["tokens"]["additionalProperties"] == false

    for key <- Tokens.token_keys() do
      assert schema["properties"]["tokens"]["properties"][key] == %{"type" => "string"}
    end

    assert schema["properties"]["base"]["enum"] == ["light", "dark"]
    assert Enum.sort(schema["required"]) == ["base", "name", "tokens"]
  end

  test "update_theme and delete_theme require the identity id" do
    assert tool("update_theme")["inputSchema"]["required"] == ["id"]
    assert tool("update_theme")["inputSchema"]["properties"]["id"]["type"] == "string"

    assert tool("delete_theme")["inputSchema"]["required"] == ["id"]
    assert tool("delete_theme")["inputSchema"]["properties"]["id"]["type"] == "string"
  end

  test "get_theme requires id and set_speech_settings exposes optional fields" do
    assert tool("get_theme")["inputSchema"]["required"] == ["id"]

    speech = tool("set_speech_settings")["inputSchema"]
    assert speech["required"] == []
    assert Enum.sort(Map.keys(speech["properties"])) == ~w(api_key clear_api_key endpoint model)
  end

  test "theme_reference is a no-input helper tool" do
    assert tool("theme_reference")["inputSchema"] == %{"type" => "object", "properties" => %{}}
  end

  test "preview_theme accepts theme_id or an unsaved base/tokens draft" do
    schema = tool("preview_theme")["inputSchema"]
    assert schema["additionalProperties"] == false
    assert schema["properties"]["base"]["enum"] == ["light", "dark"]
    assert map_size(schema["properties"]["tokens"]["properties"]) == 46
    assert [by_id, inline] = schema["oneOf"]
    assert by_id["required"] == ["theme_id"]
    assert by_id["not"]["anyOf"] == [%{"required" => ["base"]}, %{"required" => ["tokens"]}]
    assert inline == %{"required" => ["base"], "not" => %{"required" => ["theme_id"]}}
  end
end
