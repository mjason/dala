defmodule Dala.Updater.StatusTest do
  use ExUnit.Case, async: true

  alias Dala.Updater.Status

  setup do
    root =
      Dala.Paths.expand_user(
        Path.join(System.tmp_dir!(), "dala-update-status-#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "round-trips every lifecycle state", %{root: root} do
    for state <- Status.states() do
      assert :ok = Status.write(root, state, "message for #{state}", "v1.2.3")

      assert %{
               state: ^state,
               message: "message for " <> ^state,
               version: "v1.2.3",
               updated_at: updated_at
             } = Status.read(root)

      assert {:ok, _, _} = DateTime.from_iso8601(updated_at)
    end
  end

  test "missing, malformed and unknown status files are ignored", %{root: root} do
    assert Status.read(root) == nil

    File.mkdir_p!(root)
    File.write!(Status.path(root), "not json")
    assert Status.read(root) == nil

    File.write!(Status.path(root), Jason.encode!(%{state: "complete"}))
    assert Status.read(root) == nil
  end
end
