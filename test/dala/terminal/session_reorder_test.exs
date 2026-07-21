defmodule Dala.Terminal.SessionReorderTest do
  @moduledoc """
  Sidebar ordering: the `position` float attribute, the `:reorder` action
  and the position-sorted read. Sessions are seeded directly (no shell is
  spawned) except for the create-appends test, which exercises the real
  create action.
  """
  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server, Session}

  @moduletag :terminal

  defp seed!(name, position, inserted_at) do
    Ash.Seed.seed!(Session, %{
      name: name,
      shell: "/bin/bash",
      cwd: "/tmp",
      position: position,
      inserted_at: inserted_at,
      updated_at: inserted_at
    })
  end

  defp at(seconds), do: DateTime.add(~U[2026-07-01 00:00:00.000000Z], seconds)

  defp names, do: Dala.Terminal.list_sessions!() |> Enum.map(& &1.name)

  defp reorder!(session, before_id) do
    session
    |> Ash.Changeset.for_update(:reorder, %{before_id: before_id})
    |> Ash.update!()
  end

  describe "list_sessions ordering" do
    test "sorts by position, falling back to inserted_at on ties" do
      seed!("c", 3.0, at(0))
      seed!("a", 1.0, at(2))
      seed!("b", 2.0, at(1))
      assert names() == ["a", "b", "c"]

      # ties resolve by insertion order
      seed!("tie-late", 2.0, at(10))
      seed!("tie-early", 2.0, at(5))
      assert names() == ["a", "b", "tie-early", "tie-late", "c"]
    end
  end

  describe "reorder" do
    test "moving before another session persists between its neighbours" do
      a = seed!("a", 1.0, at(0))
      _b = seed!("b", 2.0, at(1))
      c = seed!("c", 3.0, at(2))

      moved = reorder!(c, a.id)
      assert moved.position < a.position
      assert names() == ["c", "a", "b"]

      # persisted: a fresh read agrees
      assert Dala.Terminal.get_session!(c.id).position == moved.position
    end

    test "moving into the middle lands between the neighbours" do
      a = seed!("a", 1.0, at(0))
      b = seed!("b", 2.0, at(1))
      c = seed!("c", 3.0, at(2))

      moved = reorder!(a, c.id)
      assert moved.position > b.position and moved.position < c.position
      assert names() == ["b", "a", "c"]
    end

    test "nil before_id moves the session to the end" do
      a = seed!("a", 1.0, at(0))
      _b = seed!("b", 2.0, at(1))
      c = seed!("c", 3.0, at(2))

      moved = reorder!(a, nil)
      assert moved.position > c.position
      assert names() == ["b", "c", "a"]
    end

    test "a vanished before_id (concurrent delete) falls back to the end" do
      a = seed!("a", 1.0, at(0))
      _b = seed!("b", 2.0, at(1))
      ghost = seed!("ghost", 9.0, at(3))
      :ok = Ash.destroy!(ghost)

      reorder!(a, ghost.id)
      assert names() == ["b", "a"]
    end

    test "reordering before itself keeps the list intact" do
      a = seed!("a", 1.0, at(0))
      _b = seed!("b", 2.0, at(1))

      reorder!(a, a.id)
      assert names() == ["a", "b"]
    end

    test "degenerate gaps (equal neighbour positions) renormalize" do
      _a = seed!("a", 1.0, at(0))
      b = seed!("b", 1.0, at(1))
      c = seed!("c", 2.0, at(2))

      reorder!(c, b.id)
      assert names() == ["a", "c", "b"]

      positions = Dala.Terminal.list_sessions!() |> Enum.map(& &1.position)
      assert positions == Enum.sort(positions)
      assert positions == Enum.uniq(positions)
    end

    test "renormalization publishes session_updated for the renumbered rows after commit" do
      # The renumbering updates run INSIDE the reorder's transaction; their
      # notifications must be collected and delivered after commit — other
      # devices sort by position and would silently diverge otherwise.
      _a = seed!("a", 1.0, at(0))
      b = seed!("b", 1.0, at(1))
      c = seed!("c", 2.0, at(2))

      DalaWeb.Endpoint.subscribe("sessions")

      log = ExUnit.CaptureLog.capture_log(fn -> reorder!(c, b.id) end)

      # Swallowed nested notifications would log Ash's missed-notifications
      # warning instead of broadcasting.
      refute log =~ "Missed"

      # The moved row's own update broadcasts...
      c_id = c.id

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sessions",
        event: "session_updated",
        payload: %{id: ^c_id}
      }

      # ...and so does the renumbered neighbour (b was pushed to 3.0).
      b_id = b.id

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "sessions",
        event: "session_updated",
        payload: %{id: ^b_id, position: 3.0}
      }
    end

    test "concurrent-ish reorders neither crash nor corrupt the list" do
      sessions = for i <- 1..5, do: seed!("s#{i}", i * 1.0, at(i))
      ids = MapSet.new(sessions, & &1.id)

      moves =
        for s <- sessions, t <- sessions, s.id != t.id, do: {s, t.id}

      results =
        moves
        |> Enum.shuffle()
        |> Task.async_stream(fn {s, before_id} -> reorder!(s, before_id) end,
          max_concurrency: 8,
          timeout: :infinity
        )

      assert Enum.all?(results, &match?({:ok, %Session{}}, &1))

      final = Dala.Terminal.list_sessions!()
      assert MapSet.new(final, & &1.id) == ids
      assert length(final) == 5
    end

    test "is exposed over rpc as reorder_session" do
      rpc_actions =
        Dala.Terminal
        |> AshTypescript.Rpc.Info.typescript_rpc()
        |> Enum.find(&(&1.resource == Session))
        |> Map.fetch!(:rpc_actions)

      assert Enum.any?(rpc_actions, &(&1.name == :reorder_session and &1.action == :reorder))
    end
  end

  describe "create" do
    test "new sessions append at the end even after reordering" do
      seed!("z-first", 5.0, at(0))

      session =
        Dala.Terminal.create_session!(%{shell: Dala.TestPlatform.shell(), name: "fresh"})

      on_exit(fn ->
        Server.shutdown_and_wait(session.id)
        File.rm(Holder.exit_path(to_string(session.id)))
        File.rm(Holder.final_path(to_string(session.id)))
        File.rm(Holder.text_final_path(to_string(session.id)))
      end)

      assert session.position > 5.0
      assert names() == ["z-first", "fresh"]
    end
  end
end
