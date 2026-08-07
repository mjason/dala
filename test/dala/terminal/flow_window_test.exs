defmodule Dala.Terminal.FlowWindowTest do
  @moduledoc """
  The high-water mark decides when the channel stops forwarding output and
  lurches to a repaint. Getting it wrong on a slow link produces exactly the
  stutter it exists to prevent, so the arithmetic is pinned here rather than
  left to an integration test that can only observe the symptom.
  """

  use ExUnit.Case, async: true

  alias Dala.Terminal.FlowWindow

  @base 128 * 1024

  # One push of `size` bytes at `at`, acknowledged `rtt` later.
  defp exchange(window, total, at, rtt) do
    window
    |> FlowWindow.sent(total, at)
    |> FlowWindow.acked(total, at + rtt)
  end

  test "with no measurement at all the base mark applies unchanged" do
    assert FlowWindow.high_water(FlowWindow.new(), @base) == @base
    assert FlowWindow.rtt_ms(FlowWindow.new()) == nil
  end

  test "a fast link does not move the mark meaningfully" do
    window =
      Enum.reduce(1..10, FlowWindow.new(), fn i, window ->
        exchange(window, i * 20_000, i * 25, 2)
      end)

    assert FlowWindow.rtt_ms(window) <= 3

    # 20 KB per 25ms ≈ 800 B/ms, times a 2ms round trip ≈ 1.6 KB.
    assert_in_delta FlowWindow.high_water(window, @base), @base, 8 * 1024
  end

  test "a slow link raises the mark by roughly its bandwidth-delay product" do
    # 500 KB/s (≈500 B/ms) at 300ms: ~150 KB is simply IN FLIGHT and must not
    # read as a backlog.
    window =
      Enum.reduce(1..10, FlowWindow.new(), fn i, window ->
        exchange(window, i * 50_000, i * 100, 300)
      end)

    assert_in_delta FlowWindow.rtt_ms(window), 300, 20

    high_water = FlowWindow.high_water(window, @base)
    bdp = 500 * 300

    assert high_water > @base, "a 300ms link must not keep the fast-link mark"
    assert_in_delta high_water, @base + bdp, 40 * 1024
  end

  test "the mark is capped so a far, fast link cannot queue unbounded memory" do
    # 10 MB/s at 2s — a satellite link doing a build log. Uncapped this would
    # authorise ~20 MB of Phoenix send queue for one session.
    window =
      Enum.reduce(1..10, FlowWindow.new(), fn i, window ->
        exchange(window, i * 10_000_000, i * 1_000, 2_000)
      end)

    assert FlowWindow.high_water(window, @base) == @base * 4
  end

  test "one stalled acknowledgement cannot inflate the mark on its own" do
    steady =
      Enum.reduce(1..20, FlowWindow.new(), fn i, window ->
        exchange(window, i * 20_000, i * 25, 2)
      end)

    # A backgrounded tab or a GC pause: a single 5s round trip.
    stalled = exchange(steady, 21 * 20_000, 21 * 25, 5_000)

    assert FlowWindow.rtt_ms(stalled) < 1_500,
           "smoothing must keep one outlier from redefining the link"
  end

  test "markers older than an acknowledgement are dropped, not re-measured" do
    window =
      FlowWindow.new()
      |> FlowWindow.sent(1_000, 0)
      |> FlowWindow.sent(2_000, 10)
      |> FlowWindow.sent(3_000, 20)
      # Covers all three; the round trip is measured against the NEWEST one
      # (30 - 20), not the oldest, which was mostly queueing.
      |> FlowWindow.acked(3_000, 30)

    assert FlowWindow.rtt_ms(window) == 10

    # Nothing outstanding: a later ack of the same total measures nothing new.
    stable = FlowWindow.acked(window, 3_000, 500)
    assert FlowWindow.rtt_ms(stable) == 10
  end

  test "acknowledgements in the same millisecond do not divide by zero" do
    window =
      FlowWindow.new()
      |> FlowWindow.sent(1_000, 5)
      |> FlowWindow.acked(1_000, 5)
      |> FlowWindow.acked(2_000, 5)
      |> FlowWindow.acked(3_000, 5)

    assert FlowWindow.high_water(window, @base) >= @base
  end

  test "a re-sent lower watermark replaces the stale marker" do
    # A channel rejoin restarts the ledger; a marker from the old generation
    # must not sit there forever waiting for a total that will never arrive.
    window =
      FlowWindow.new()
      |> FlowWindow.sent(9_000, 0)
      |> FlowWindow.sent(1_000, 100)
      |> FlowWindow.acked(1_000, 150)

    assert FlowWindow.rtt_ms(window) == 50
  end
end
