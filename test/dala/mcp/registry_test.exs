defmodule Dala.Mcp.RegistryTest do
  # Pure introspection over the Settings domain — no DB, no app-env mutation.
  use ExUnit.Case, async: true

  alias Dala.Mcp.Registry
  alias Dala.Settings.Theme.Tokens

  defp tool(name), do: Enum.find(Registry.tools(), &(&1["name"] == name))

  test "auto-derives a tool per rpc_action plus the theme_reference helper" do
    names = Enum.map(Registry.tools(), & &1["name"])

    for expected <- ~w(speech_settings set_speech_settings list_themes get_theme
                       create_theme update_theme delete_theme theme_reference) do
      assert expected in names, "expected #{expected} in #{inspect(names)}"
    end
  end

  test "create_theme inputSchema inlines all 39 token keys and a light|dark base enum" do
    schema = tool("create_theme")["inputSchema"]

    assert map_size(schema["properties"]["tokens"]["properties"]) == Tokens.count()
    assert map_size(schema["properties"]["tokens"]["properties"]) == 39
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
end
