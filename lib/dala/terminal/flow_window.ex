defmodule Dala.Terminal.FlowWindow do
  @moduledoc """
  Bandwidth-delay product for the terminal channel's output flow control.

  `DalaWeb.TerminalChannel` stops forwarding output and asks the holder for a
  repaint once `sent - acked` passes a high-water mark. A FIXED mark is
  RTT-blind, and that is a problem in exactly the situation flow control
  exists for: the bytes merely IN FLIGHT on a healthy link are bandwidth x
  round-trip, so a 300ms connection moving 500 KB/s sits permanently at 150 KB
  of backlog without anything being wrong. Against the 128 KiB alternate-screen
  mark it would spend its whole life in skip-then-repaint cycles — the screen
  freezing and lurching, which is the very stutter the mark was meant to
  prevent.

  So the mark is the base plus the MEASURED product, capped so that a fast and
  far link cannot queue unbounded memory into the socket.

  Both inputs come from acknowledgements the client already sends: the delay
  from how long a byte count takes to come back, the rate from how fast the
  acknowledged total climbs.
  """

  @typedoc "Opaque measurement state; one per connected client."
  @type t :: %{
          markers: [{non_neg_integer(), integer()}],
          rtt_ms: number() | nil,
          rate_bpms: number() | nil,
          last_ack: {non_neg_integer(), integer()} | nil
        }

  # Enough in-flight markers to survive a burst of pushes between two acks,
  # few enough that the list stays cheaper than any queue structure.
  @max_markers 16

  # Weight of each new sample. Low enough that one stalled ack (a GC pause, a
  # backgrounded browser tab) cannot inflate the window on its own.
  @smoothing 0.25

  # A hard ceiling in multiples of the base mark. Without it a 2s satellite
  # link would authorise megabytes of Phoenix send queue per session.
  @cap_factor 4

  @doc "Fresh state — no measurement yet, so the base mark applies unchanged."
  @spec new() :: t()
  def new, do: %{markers: [], rtt_ms: nil, rate_bpms: nil, last_ack: nil}

  @doc """
  Record that `total` cumulative bytes have now been pushed to the client.
  """
  @spec sent(t(), non_neg_integer(), integer()) :: t()
  def sent(window, total, now_ms) do
    markers =
      window.markers
      |> Enum.reject(fn {watermark, _at} -> watermark >= total end)
      |> Kernel.++([{total, now_ms}])
      |> Enum.take(-@max_markers)

    %{window | markers: markers}
  end

  @doc """
  Fold in an acknowledgement of `total` cumulative bytes.

  The delay sample comes from the NEWEST marker the acknowledgement covers:
  older ones were already in flight when it was sent and would report a delay
  that is mostly queueing, not round-trip.
  """
  @spec acked(t(), non_neg_integer(), integer()) :: t()
  def acked(window, total, now_ms) do
    {covered, pending} =
      Enum.split_with(window.markers, fn {watermark, _at} -> watermark <= total end)

    window = %{window | markers: pending}

    window
    |> fold_rtt(List.last(covered), now_ms)
    |> fold_rate(total, now_ms)
  end

  @doc """
  The high-water mark for a client, given the mark that would apply with no
  measurement at all.
  """
  @spec high_water(t(), pos_integer()) :: pos_integer()
  def high_water(%{rtt_ms: rtt, rate_bpms: rate}, base)
      when is_number(rtt) and is_number(rate) and rtt > 0 and rate > 0 do
    min(base + round(rate * rtt), base * @cap_factor)
  end

  def high_water(_window, base), do: base

  @doc "Measured round-trip in ms, or nil before the first sample (debug)."
  @spec rtt_ms(t()) :: number() | nil
  def rtt_ms(window), do: window.rtt_ms

  defp fold_rtt(window, nil, _now_ms), do: window

  defp fold_rtt(window, {_watermark, at}, now_ms) do
    %{window | rtt_ms: smooth(window.rtt_ms, max(now_ms - at, 0))}
  end

  defp fold_rate(window, total, now_ms) do
    case window.last_ack do
      {previous_total, previous_at} when now_ms > previous_at and total > previous_total ->
        sample = (total - previous_total) / (now_ms - previous_at)
        %{window | rate_bpms: smooth(window.rate_bpms, sample), last_ack: {total, now_ms}}

      {previous_total, previous_at} when now_ms <= previous_at and total > previous_total ->
        # Same millisecond: keep the rate, but move the anchor so the next
        # sample measures from here rather than reporting an inflated jump.
        %{window | last_ack: {max(total, previous_total), previous_at}}

      _no_usable_previous ->
        %{window | last_ack: {total, now_ms}}
    end
  end

  defp smooth(nil, sample), do: sample
  defp smooth(current, sample), do: current * (1 - @smoothing) + sample * @smoothing
end
