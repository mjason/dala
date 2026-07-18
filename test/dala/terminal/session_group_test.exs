defmodule Dala.Terminal.SessionGroupTest do
  @moduledoc """
  The `:set_group` action behind the sidebar's manual grouping (right-click →
  move to group). Sessions are seeded directly (no shell is spawned) — the
  action only touches the `group` attribute.
  """
  use Dala.DataCase, async: false

  alias Dala.Terminal.Session

  @moduletag :terminal

  defp seed!(attrs \\ %{}) do
    Ash.Seed.seed!(
      Session,
      Map.merge(%{name: "s", shell: "/bin/bash", cwd: "/tmp", position: 1.0}, attrs)
    )
  end

  defp set_group(session, group) do
    session
    |> Ash.Changeset.for_update(:set_group, %{group: group})
    |> Ash.update()
  end

  describe "set_group" do
    test "assigns a group name" do
      session = seed!()

      assert {:ok, updated} = set_group(session, "work")
      assert updated.group == "work"
      assert Dala.Terminal.get_session!(session.id).group == "work"
    end

    test "nil ungroups" do
      session = seed!(%{group: "work"})

      assert {:ok, updated} = set_group(session, nil)
      assert updated.group == nil
    end

    test "an overlong name is rejected" do
      session = seed!()

      assert {:error, %Ash.Error.Invalid{}} = set_group(session, String.duplicate("x", 101))
    end
  end
end
