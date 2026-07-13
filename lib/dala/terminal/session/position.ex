defmodule Dala.Terminal.Session.Position do
  @moduledoc """
  Float sort keys for the session sidebar.

  A reorder writes only the moved row: its new position is the midpoint of
  its new neighbours (or last + 1.0 at the end). Concurrent reorders from
  two devices therefore can't corrupt the list — each writes one row and
  the last write wins. When a gap underflows (repeated bisection of the
  same spot, or seeded ties), all rows are renumbered to 1.0..n first.

  These functions run inside the caller's action transaction (a
  `before_action` hook), so the renumbering updates collect their
  notifications instead of publishing mid-transaction; the caller returns
  them from its hook so Ash delivers them after commit — other devices must
  see the renumbered rows.
  """

  alias Dala.Terminal.Session

  @doc "Position for a newly created session: after everything else."
  def append_position do
    case ordered_sessions() do
      [] -> 1.0
      sessions -> List.last(sessions).position + 1.0
    end
  end

  @doc """
  Position that puts `moved_id` before `before_id` (nil or vanished
  `before_id` → the end). May renumber other rows when out of float gap;
  returns `{position, notifications}` — the notifications of any renumbered
  rows, to be sent after the surrounding transaction commits.
  """
  def reorder_position(moved_id, before_id) do
    others = Enum.reject(ordered_sessions(), &(&1.id == moved_id))

    case Enum.find_index(others, &(&1.id == before_id)) do
      nil -> {after_last(others), []}
      index -> between(others, index)
    end
  end

  defp after_last([]), do: 1.0
  defp after_last(others), do: List.last(others).position + 1.0

  defp between(others, 0) do
    first = hd(others).position
    {if(first > 0.0, do: first / 2, else: first - 1.0), []}
  end

  defp between(others, index) do
    prev = Enum.at(others, index - 1).position
    next = Enum.at(others, index).position
    mid = (prev + next) / 2

    if mid > prev and mid < next do
      {mid, []}
    else
      renormalize(others, index)
    end
  end

  # Renumber every other row to 1.0..n, leaving the slot `index` (counted in
  # `others`) free for the moved session. Returns {position, notifications}.
  defp renormalize(others, index) do
    notifications =
      others
      |> Enum.with_index()
      |> Enum.flat_map(fn {session, i} ->
        position = if i < index, do: i + 1.0, else: i + 2.0

        if session.position != position do
          # Inside the reorder's transaction: collect instead of notify —
          # notifying here would be swallowed (and warn about missed
          # notifications); the caller sends these after commit.
          {_session, notifications} =
            session
            |> Ash.Changeset.for_update(:set_position, %{position: position})
            |> Ash.update!(return_notifications?: true)

          notifications
        else
          []
        end
      end)

    {index + 1.0, notifications}
  end

  defp ordered_sessions do
    Ash.read!(Session, action: :list)
  end
end
