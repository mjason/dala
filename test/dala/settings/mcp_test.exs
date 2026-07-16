defmodule Dala.Settings.McpTest do
  use Dala.DataCase, async: false

  alias Dala.Settings.Mcp

  defp current do
    Mcp |> Ash.ActionInput.for_action(:current, %{}) |> Ash.run_action!()
  end

  defp set_enabled(value) do
    Mcp |> Ash.ActionInput.for_action(:set_enabled, %{enabled: value}) |> Ash.run_action!()
  end

  defp regenerate do
    Mcp |> Ash.ActionInput.for_action(:regenerate_token, %{}) |> Ash.run_action!()
  end

  describe ":current (singleton provisioning)" do
    test "first read auto-provisions a high-entropy token, enabled defaults to false" do
      result = current()

      assert result.enabled == false
      assert result.terminal_read == false
      assert result.terminal_control == false
      assert is_binary(result.token)
      # 24 random bytes -> 32 url-safe base64 chars.
      assert String.length(result.token) >= 32
      assert result.token =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "repeated reads return the SAME token and never create a second row" do
      first = current()
      second = current()

      assert first.token == second.token
      assert length(Ash.read!(Mcp, authorize?: false)) == 1
    end
  end

  describe ":set_enabled" do
    test "toggles enabled without touching the token" do
      %{token: token} = current()

      assert set_enabled(true) == %{
               enabled: true,
               token: token,
               terminal_read: false,
               terminal_control: false
             }

      assert current().token == token
      assert current().enabled == true

      assert set_enabled(false) == %{
               enabled: false,
               token: token,
               terminal_read: false,
               terminal_control: false
             }

      assert current().enabled == false
    end
  end

  describe ":set_terminal_access" do
    test "control requires read and disabling read also disables control" do
      current()

      enabled = Mcp.set_terminal_access(true, true)
      assert enabled.terminal_read
      assert enabled.terminal_control
      assert Mcp.terminal_access() == %{read: true, control: true}

      disabled = Mcp.set_terminal_access(false, true)
      refute disabled.terminal_read
      refute disabled.terminal_control
      assert Mcp.terminal_access() == %{read: false, control: false}
    end
  end

  describe ":regenerate_token" do
    test "returns a NEW token; the old one stops authorizing immediately" do
      %{token: old} = current()

      %{token: new} = regenerate()
      assert new != old
      assert String.length(new) >= 32

      # The live/stored token the gate compares against is now the new one.
      {_enabled, live} = Mcp.config()
      assert live == new
      refute live == old
    end

    test "does not create a duplicate singleton" do
      current()
      regenerate()
      assert length(Ash.read!(Mcp, authorize?: false)) == 1
    end
  end

  describe "config/0 (the authed provision-and-read path)" do
    test "provisions and returns {enabled, token}" do
      {enabled, token} = Mcp.config()
      assert enabled == false
      assert is_binary(token) and String.length(token) >= 32
    end
  end

  describe "config_or_default/0 (the unauthenticated gate's read-only path)" do
    test "a missing singleton reads as {false, nil} WITHOUT provisioning a row" do
      assert Mcp.config_or_default() == {false, nil}
      # The gate runs before auth on every /mcp request; it must NEVER write —
      # no singleton row may be created just by probing a disabled endpoint.
      assert Ash.read!(Mcp, authorize?: false) == []
    end

    test "returns the stored {enabled, token} once the row exists" do
      %{token: token} = current()
      set_enabled(true)
      assert Mcp.config_or_default() == {true, token}
    end
  end

  describe "concurrency safety" do
    test "a second :provision for the same singleton is idempotent (no crash, token kept)" do
      %{token: original} = current()
      [row] = Ash.read!(Mcp, authorize?: false)

      # Simulate a racing caller that also runs :provision for the same id with
      # a different token. The upsert must NOT raise on the primary-key conflict
      # and must NOT clobber the already-live token.
      assert {:ok, _} =
               Ash.create(
                 Mcp,
                 %{id: row.id, enabled: true, token: "racing-token-must-be-ignored-abc123"},
                 action: :provision,
                 authorize?: false
               )

      assert length(Ash.read!(Mcp, authorize?: false)) == 1
      {_enabled, live} = Mcp.config()
      assert live == original
    end
  end
end
