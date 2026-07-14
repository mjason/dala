defmodule Dala.Terminal.SessionRenameTest do
  @moduledoc """
  The `:rename` action behind F2 / double-click in the sidebar and the
  settings modal. Sessions are seeded directly (no shell is spawned) — the
  action only touches the `name` attribute.
  """
  use Dala.DataCase, async: false

  alias Dala.Terminal.Session

  @moduletag :terminal

  defp seed!(name) do
    Ash.Seed.seed!(Session, %{name: name, shell: "/bin/bash", cwd: "/tmp", position: 1.0})
  end

  defp rename(session, name) do
    session
    |> Ash.Changeset.for_update(:rename, %{name: name})
    |> Ash.update()
  end

  describe "rename" do
    test "a valid name persists" do
      session = seed!("old")

      assert {:ok, renamed} = rename(session, "new name")
      assert renamed.name == "new name"
      assert Dala.Terminal.get_session!(session.id).name == "new name"
    end

    test "surrounding whitespace is trimmed" do
      session = seed!("old")

      assert {:ok, renamed} = rename(session, "  padded  ")
      assert renamed.name == "padded"
    end

    test "an empty or whitespace-only name is rejected" do
      session = seed!("old")

      for blank <- ["", "   ", "\t\n"] do
        assert {:error, %Ash.Error.Invalid{}} = rename(session, blank)
      end

      assert Dala.Terminal.get_session!(session.id).name == "old"
    end

    test "a nil name is rejected" do
      session = seed!("old")

      assert {:error, %Ash.Error.Invalid{}} = rename(session, nil)
      assert Dala.Terminal.get_session!(session.id).name == "old"
    end

    test "the name is capped at 200 characters" do
      session = seed!("old")

      assert {:ok, renamed} = rename(session, String.duplicate("a", 200))
      assert String.length(renamed.name) == 200

      assert {:error, %Ash.Error.Invalid{}} = rename(session, String.duplicate("a", 201))
      assert Dala.Terminal.get_session!(session.id).name == String.duplicate("a", 200)
    end

    test "renaming broadcasts session_updated so every device follows" do
      session = seed!("old")
      DalaWeb.Endpoint.subscribe("sessions")

      assert {:ok, _} = rename(session, "renamed")

      id = session.id

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sessions",
        event: "session_updated",
        payload: %{id: ^id, name: "renamed"}
      }
    end

    test "is exposed over rpc as rename_session" do
      rpc_actions =
        Dala.Terminal
        |> AshTypescript.Rpc.Info.typescript_rpc()
        |> Enum.find(&(&1.resource == Session))
        |> Map.fetch!(:rpc_actions)

      assert Enum.any?(rpc_actions, &(&1.name == :rename_session and &1.action == :rename))
    end
  end
end
