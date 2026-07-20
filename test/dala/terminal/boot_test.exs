defmodule Dala.Terminal.BootTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.Boot
  import ExUnit.CaptureLog

  test "run_bounded/3 never exceeds the configured concurrency" do
    parent = self()

    worker = fn item ->
      send(parent, {:started, item, self()})
      receive do: (:release -> item)
    end

    task = Task.async(fn -> Boot.run_bounded(1..8, worker, max_concurrency: 4) end)

    first_wave =
      for _ <- 1..4 do
        assert_receive {:started, item, pid}, 500
        {item, pid}
      end

    refute_receive {:started, _, _}, 50
    Enum.each(first_wave, fn {_item, pid} -> send(pid, :release) end)

    second_wave =
      for _ <- 1..4 do
        assert_receive {:started, item, pid}, 500
        {item, pid}
      end

    Enum.each(second_wave, fn {_item, pid} -> send(pid, :release) end)
    assert Task.await(task) == :ok
  end

  test "one failed item does not prevent later work" do
    parent = self()

    capture_log(fn ->
      assert :ok =
               Boot.run_bounded([:good, :bad, :later], fn
                 :bad -> raise "boom"
                 item -> send(parent, {:completed, item})
               end)
    end)

    assert_receive {:completed, :good}
    assert_receive {:completed, :later}
  end
end
