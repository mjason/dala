defmodule Dala.MixProjectTest do
  use ExUnit.Case, async: true

  test "npm status polling rejects an exhausted negative attempt budget immediately" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "dala-missing-npm-status-#{System.unique_integer([:positive])}"
      )

    assert_raise Mix.Error, "npm run check timed out", fn ->
      Dala.MixProject.wait_for_npm_status(missing, -1)
    end
  end
end
