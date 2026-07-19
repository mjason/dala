defmodule Dala.Terminal.SessionBroadcastIntegrityTest do
  @moduledoc """
  `session_updated` broadcasts must carry the COMMITTED row, never the
  caller's in-memory copy.

  The real bug this pins down: `Dala.Terminal.Server` holds the session
  struct it loaded at spawn and updates through it (cwd polls every 2s,
  mark_exited on shell exit). A rename/reorder/regroup over RPC never
  touches that copy — so the next cwd/status update broadcast a payload
  with the OLD name/position/group, reverting every connected sidebar
  until a manual refresh.
  """
  use Dala.DataCase, async: false

  alias Dala.Terminal.Session

  @moduletag :terminal

  defp seed!(attrs \\ %{}) do
    Ash.Seed.seed!(
      Session,
      Map.merge(%{name: "old", shell: "/bin/bash", cwd: "/tmp", position: 1.0}, attrs)
    )
  end

  defp rename!(session, name) do
    session |> Ash.Changeset.for_update(:rename, %{name: name}) |> Ash.update!()
  end

  defp set_group!(session, group) do
    session |> Ash.Changeset.for_update(:set_group, %{group: group}) |> Ash.update!()
  end

  defp assert_updated_payload(id) do
    assert_receive %Phoenix.Socket.Broadcast{
      topic: "sessions",
      event: "session_updated",
      payload: %{id: ^id} = payload
    }

    payload
  end

  describe "updates through a stale struct (the Terminal.Server pattern)" do
    test "a cwd poll after a rename must not broadcast the old name back" do
      stale = seed!()
      rename!(stale, "renamed")

      DalaWeb.Endpoint.subscribe("sessions")
      # The server's cwd poll fires with the struct it loaded at spawn.
      assert {:ok, _} = Dala.Terminal.update_cwd(stale, %{cwd: "/"})

      payload = assert_updated_payload(stale.id)
      assert payload.name == "renamed"
      assert payload.cwd == "/"
    end

    test "a cwd poll after reorder/regroup must not broadcast old position/group" do
      stale = seed!(%{position: 1.0})

      stale
      |> Ash.Changeset.for_update(:set_position, %{position: 7.5})
      |> Ash.update!()

      set_group!(stale, "work")

      DalaWeb.Endpoint.subscribe("sessions")
      assert {:ok, _} = Dala.Terminal.update_cwd(stale, %{cwd: "/"})

      payload = assert_updated_payload(stale.id)
      assert payload.position == 7.5
      assert payload.group == "work"
    end

    test "mark_exited through a stale struct keeps the renamed name" do
      stale = seed!()
      rename!(stale, "renamed")

      DalaWeb.Endpoint.subscribe("sessions")
      assert {:ok, _} = Dala.Terminal.mark_exited(stale, %{exit_code: 0})

      payload = assert_updated_payload(stale.id)
      assert payload.name == "renamed"
      assert payload.status == :exited
      assert payload.exitCode == 0
    end

    test "mark_running (restart) through a stale struct keeps the renamed name" do
      stale = seed!()
      rename!(stale, "renamed")

      DalaWeb.Endpoint.subscribe("sessions")
      assert Dala.Terminal.mark_running!(stale)

      payload = assert_updated_payload(stale.id)
      assert payload.name == "renamed"
      assert payload.status == :running
    end
  end
end
