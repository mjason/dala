defmodule Dala.Terminal.Session.Payloads do
  @moduledoc """
  PubSub publication transforms for `Dala.Terminal.Session`.

  Typed channels have no runtime formatting layer — whatever these functions
  return goes over the wire verbatim — so keys are camelCase to match the
  generated TypeScript payload types.
  """

  def summary(%Ash.Notifier.Notification{data: session}) do
    %{
      id: session.id,
      name: session.name,
      shell: session.shell,
      cwd: session.cwd,
      status: session.status,
      exitCode: session.exit_code,
      scrollbackLimit: session.scrollback_limit,
      ephemeral: session.ephemeral,
      position: session.position,
      insertedAt: session.inserted_at
    }
  end

  def deleted(%Ash.Notifier.Notification{data: session}) do
    %{id: session.id}
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
      position: [type: :float, allow_nil?: false],
      insertedAt: [type: :utc_datetime_usec, allow_nil?: false]
    ]
  end
end
