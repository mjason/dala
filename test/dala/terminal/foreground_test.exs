defmodule Dala.Terminal.ForegroundTest do
  @moduledoc """
  Telling a plain prompt from a running CLI agent — this is what decides how
  composer text is delivered, so a wrong answer types into the wrong reader.

  The positive case needs a real PTY and lives in `Dala.Terminal.SessionTest`
  ("foreground_app reports the running command"). What is pinned here is the
  edges: this runs for every agent-command lookup, and a raise would take the
  session's GenServer down with it.
  """

  use ExUnit.Case, async: true

  alias Dala.Terminal.Foreground

  test "an absent, dead or nonsense pid is nil, never a raise" do
    assert Foreground.cmdline(999_999_999) == nil
    assert Foreground.cmdline(nil) == nil
    assert Foreground.cmdline(-5) == nil
    assert Foreground.cmdline(0) == nil
    assert Foreground.cmdline("100") == nil
    assert Foreground.cmdline(:not_a_pid) == nil
  end

  test "a process with no controlling terminal reports no foreground program" do
    if File.dir?("/proc") do
      # A port's child is spawned without a tty, so its stat carries tpgid -1 —
      # the case that must read as "nothing in the foreground".
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [
          :binary,
          args: ["30"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
      end)

      assert Foreground.cmdline(os_pid) == nil
    end
  end
end
