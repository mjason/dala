defmodule Dala.Terminal.ProcessSnapshotTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.ProcessSnapshot

  test "parse/1 keeps command arguments while ignoring malformed rows" do
    output = """
      100     1 -zsh
      200   100 zellij attach project with spaces
      malformed
      300   200
    """

    assert ProcessSnapshot.parse(output) == [
             {100, 1, "-zsh"},
             {200, 100, "zellij attach project with spaces"}
           ]
  end
end
