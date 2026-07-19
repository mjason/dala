defmodule Dala.Terminal.Session.Payloads do
  @moduledoc """
  PubSub publication transforms for `Dala.Terminal.Session`.

  Typed channels have no runtime formatting layer — whatever these functions
  return goes over the wire verbatim — so keys are camelCase to match the
  generated TypeScript payload types.
  """

  def summary(%Ash.Notifier.Notification{data: session}) do
    session = reload(session)

    %{
      id: session.id,
      name: session.name,
      shell: session.shell,
      cwd: session.cwd,
      status: session.status,
      exitCode: session.exit_code,
      scrollbackLimit: session.scrollback_limit,
      ephemeral: session.ephemeral,
      group: session.group,
      position: session.position,
      insertedAt: session.inserted_at,
      updatedAt: session.updated_at
    }
  end

  def deleted(%Ash.Notifier.Notification{data: session}) do
    %{id: session.id}
  end

  # The notification's :data is whatever record the ACTION returned — and
  # callers like Dala.Terminal.Server update through the struct they loaded
  # at spawn, so every untouched field in it can be stale (a cwd poll after
  # a rename used to broadcast the old name back to every sidebar). The
  # summary re-reads the committed row instead: the broadcast is
  # authoritative no matter how old the caller's copy was. Notifications
  # dispatch after commit, so the read always sees this update (or a newer
  # one, whose own notification follows — either way, never older state).
  defp reload(session) do
    case Dala.Terminal.get_session(session.id) do
      {:ok, fresh} -> fresh
      # Row already deleted (quick-shell teardown race): the returned copy
      # is the last known state, and a session_deleted follows anyway.
      {:error, _error} -> session
    end
  end

  def exit_summary(%Ash.Notifier.Notification{data: session}) do
    %{id: session.id, exitCode: session.exit_code}
  end

  def cwd_summary(%Ash.Notifier.Notification{data: session}) do
    %{id: session.id, cwd: session.cwd}
  end

  def summary_fields do
    [
      id: [type: :uuid, allow_nil?: false],
      name: [type: :string, allow_nil?: false],
      shell: [type: :string, allow_nil?: false],
      cwd: [type: :string, allow_nil?: false],
      status: [type: :atom, constraints: [one_of: [:running, :exited]], allow_nil?: false],
      exitCode: [type: :integer],
      scrollbackLimit: [type: :integer, allow_nil?: false],
      ephemeral: [type: :boolean, allow_nil?: false],
      group: [type: :string],
      position: [type: :float, allow_nil?: false],
      insertedAt: [type: :utc_datetime_usec, allow_nil?: false],
      # Row version for the client: merges keep whichever copy is newer, so
      # an out-of-order or raced broadcast can never roll a session back.
      updatedAt: [type: :utc_datetime_usec, allow_nil?: false]
    ]
  end
end
