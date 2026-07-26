defmodule Dala.Terminal.AttachedShellTest do
  @moduledoc """
  Attached shells: extra terminals that belong to a session, shown as tabs next
  to its main shell (the tmux model). They are ordinary sessions in every way
  that matters — own PTY, own holder, survive a dala restart — except that they
  hang off a parent instead of standing on their own in the sidebar, and `exit`
  inside one closes just that tab.
  """

  use Dala.TerminalCase, async: false

  defp attached_shell!(parent, attrs \\ %{}) do
    create_session!(Map.merge(%{parent_id: parent.id, cwd: parent.cwd}, attrs))
  end

  describe "creation" do
    test "an attached shell hangs off its parent and runs its own shell" do
      parent = create_session!()
      child = attached_shell!(parent)

      assert child.parent_id == parent.id
      assert child.id != parent.id
      refute parent.parent_id

      pid = Server.whereis(child.id)
      assert is_pid(pid)
      eventually("child shell is up", fn -> is_integer(:sys.get_state(pid).shell_pid) end)

      # Its own PTY, not a view onto the parent's.
      assert Server.whereis(parent.id) != pid
    end

    test "attached shells default to a name that tells the tabs apart" do
      parent = create_session!(%{cwd: System.tmp_dir!()})
      first = attached_shell!(parent)
      second = attached_shell!(parent)

      assert first.name != second.name
      assert first.name != parent.name
    end

    test "an attached shell inherits the parent's directory unless told otherwise" do
      dir = System.tmp_dir!()
      parent = create_session!(%{cwd: dir})

      assert attached_shell!(parent).cwd == dir
    end

    test "shells cannot be nested: a child of a child attaches to the root" do
      parent = create_session!()
      child = attached_shell!(parent)
      grandchild = attached_shell!(child)

      assert grandchild.parent_id == parent.id
    end
  end

  describe "listing" do
    test "attached shells are listed with their parent id so the UI can group them" do
      parent = create_session!()
      child = attached_shell!(parent)

      listed = Dala.Terminal.list_sessions!()
      ids = Enum.map(listed, & &1.id)

      assert parent.id in ids
      assert child.id in ids

      assert Enum.find(listed, &(&1.id == child.id)).parent_id == parent.id
    end
  end

  describe "lifecycle" do
    test "deleting a session takes its attached shells with it" do
      parent = create_session!()
      first = attached_shell!(parent)
      second = attached_shell!(parent)

      first_holder = Holder.socket_path(to_string(first.id))
      eventually("holders are up", fn -> File.exists?(first_holder) end)

      :ok = Dala.Terminal.delete_session(parent)

      assert {:error, _} = Dala.Terminal.get_session(first.id)
      assert {:error, _} = Dala.Terminal.get_session(second.id)
      refute Server.alive?(first.id)
      refute Server.alive?(second.id)

      # No orphan holder is left behind holding a shell open.
      eventually("holder socket is gone", fn -> not File.exists?(first_holder) end)
    end

    test "deleting one attached shell leaves the parent and its siblings alone" do
      parent = create_session!()
      first = attached_shell!(parent)
      second = attached_shell!(parent)

      :ok = Dala.Terminal.delete_session(first)

      assert {:error, _} = Dala.Terminal.get_session(first.id)
      assert {:ok, _} = Dala.Terminal.get_session(second.id)
      assert {:ok, _} = Dala.Terminal.get_session(parent.id)
    end

    test "exiting the shell closes that tab and nothing else" do
      parent = create_session!()
      child = attached_shell!(parent)
      pid = Server.whereis(child.id)
      eventually("child shell is up", fn -> is_integer(:sys.get_state(pid).shell_pid) end)

      Server.input(child.id, "exit\r")

      eventually("the tab is gone", fn ->
        match?({:error, _}, Dala.Terminal.get_session(child.id))
      end)

      assert {:ok, %{status: :running}} = Dala.Terminal.get_session(parent.id)
    end

    test "a running attached shell is reattached after a dala restart" do
      parent = create_session!()
      child = attached_shell!(parent)
      pid = Server.whereis(child.id)
      eventually("child shell is up", fn -> is_integer(:sys.get_state(pid).shell_pid) end)

      # What a BEAM restart looks like to the session: the server is gone, the
      # holder (and the shell inside it) is not.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert File.exists?(Holder.socket_path(to_string(child.id)))
      Dala.Terminal.Boot.run()

      eventually("the shell is reattached", fn -> Server.alive?(child.id) end)
      assert Dala.Terminal.get_session!(child.id).parent_id == parent.id
    end
  end
end
