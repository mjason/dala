defmodule Dala.Terminal.Pacing do
  @moduledoc """
  How often a session does periodic work: how long output is batched before it
  is broadcast, and how soon the next cwd poll runs.

  Pure arithmetic over constants, kept out of `Dala.Terminal.Server` so its
  public API stays the session API (attach, input, resize, wait…) and so the
  policy can be exercised without a live session.
  """

  # Output micro-batching window: chunks landing within it after the first are
  # coalesced into one broadcast. It ADAPTS — the floor keeps keystroke echo
  # immediate, and a shell that keeps the window full (build logs, TUI redraw
  # storms) widens it toward the ceiling, where one broadcast replaces several:
  # each one costs a payload map, a PubSub fan-out, and per client a JSON encode
  # plus a compressed websocket frame. The ceiling stays inside a single render
  # frame, so nothing is felt.
  @out_batch_ms 5
  @out_batch_max_ms 20
  # Silence this long means the storm is over: the next window opens tight
  # again. Without it a widened window would outlive the burst that earned it,
  # and the first redraw after a keystroke would sit in a batch it does not need.
  @out_idle_ms 100

  @cwd_poll_hidden_ms 30_000
  # A cwd poll this slow means its `/proc` read is starving — a saturated CPU,
  # or a filesystem that is not answering. Polling at the same cadence then only
  # adds to the contention.
  @cwd_poll_slow_ms 500
  @cwd_poll_backoff 4

  @doc "The tight output batch window used while a session is interactive."
  @spec out_window_floor() :: pos_integer()
  def out_window_floor, do: @out_batch_ms

  @doc "The widest output batch window, still inside one render frame."
  @spec out_window_ceiling() :: pos_integer()
  def out_window_ceiling, do: @out_batch_max_ms

  @doc """
  The next output batch window. `coalesced?` reports whether the window that
  just closed had actually buffered anything behind its first chunk: while it
  keeps doing so the shell is flooding, so widen; the moment one closes empty
  the session is interactive again and the floor is restored.
  """
  @spec next_out_window(pos_integer(), boolean()) :: pos_integer()
  def next_out_window(_current, false), do: @out_batch_ms

  def next_out_window(current, true), do: min(current * 2, @out_batch_max_ms)

  @doc """
  The window to open for a chunk arriving `gap_ms` after the last one. A gap
  long enough to count as silence retires whatever width the previous burst
  earned, so interactive output is never batched on the strength of a storm
  that has already ended.
  """
  @spec out_window_after_gap(pos_integer(), integer()) :: pos_integer()
  def out_window_after_gap(_current, gap_ms) when gap_ms >= @out_idle_ms, do: @out_batch_ms

  def out_window_after_gap(current, _gap_ms), do: current

  @doc """
  The delay before the next cwd poll, given how long the one that just finished
  took. A slow poll backs the cadence off proportionally, never past the
  background cadence a hidden session already uses.
  """
  @spec next_cwd_poll_interval(pos_integer(), integer()) :: pos_integer()
  def next_cwd_poll_interval(base_interval, duration_ms) when duration_ms >= @cwd_poll_slow_ms,
    do: min(base_interval * @cwd_poll_backoff, @cwd_poll_hidden_ms)

  def next_cwd_poll_interval(base_interval, _duration_ms), do: base_interval
end
