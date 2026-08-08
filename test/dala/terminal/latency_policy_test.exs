defmodule Dala.Terminal.LatencyPolicyTest do
  @moduledoc """
  One measurement, two consumers with opposite needs.

  `Dala.Terminal.FlowWindow` turns a client's acknowledgements into a round
  trip. That number sizes the client's flow-control watermark (a BANDWIDTH
  budget, per client) and, through here, the holder's frame batching window (a
  FRESHNESS budget, one per session). The aggregation below is what reconciles
  "per client" with "one per session".
  """

  use ExUnit.Case, async: true

  alias Dala.Terminal.Server

  defp pids(count), do: Enum.map(1..count, fn _ -> spawn(fn -> :ok end) end)

  describe "which client's round trip the holder is told about" do
    test "nothing measured yet means nothing to report" do
      assert Server.effective_rtt(%{}, MapSet.new()) == nil
    end

    test "the most latency-sensitive VISIBLE viewer wins" do
      [local, remote] = pids(2)

      # A phone on 4G and a laptop on localhost looking at the same session.
      # The window is a freshness budget, so it has to suit whoever notices
      # delay first; the phone's bandwidth is protected separately by its own
      # watermark.
      assert Server.effective_rtt(
               %{local => 2, remote => 240},
               MapSet.new([local, remote])
             ) == 2
    end

    test "a hidden viewer does not get to dictate the window" do
      [visible, pooled] = pids(2)

      # A warm pooled terminal stays attached but nobody is looking at it.
      assert Server.effective_rtt(
               %{visible => 180, pooled => 1},
               MapSet.new([visible])
             ) == 180
    end

    test "attached but never measured is simply absent" do
      [measured, silent] = pids(2)

      assert Server.effective_rtt(
               %{measured => 45},
               MapSet.new([measured, silent])
             ) == 45
    end

    test "everyone leaving clears the measurement" do
      [gone] = pids(1)
      assert Server.effective_rtt(%{gone => 30}, MapSet.new()) == nil
    end
  end

  describe "when a change is worth a socket write" do
    test "the first measurement is always reported" do
      assert Server.rtt_worth_reporting?(12, nil)
    end

    test "jitter inside a fifth of the current value is ignored" do
      # A window that moves by a millisecond changes nothing a person can see,
      # and this runs on every acknowledgement.
      refute Server.rtt_worth_reporting?(101, 100)
      refute Server.rtt_worth_reporting?(90, 100)
      refute Server.rtt_worth_reporting?(119, 100)
    end

    test "a real move in the link is reported" do
      assert Server.rtt_worth_reporting?(160, 100)
      assert Server.rtt_worth_reporting?(40, 100)
    end

    test "small values still need an absolute floor to avoid churn" do
      # A fifth of 3 is 0, which would make every single sample "worth it".
      refute Server.rtt_worth_reporting?(4, 3)
      assert Server.rtt_worth_reporting?(9, 3)
    end

    test "losing every viewer does not push a report" do
      # There is nothing meaningful to send, and the holder's last value is a
      # better guess than a reset for the next viewer.
      refute Server.rtt_worth_reporting?(nil, 100)
    end
  end
end
