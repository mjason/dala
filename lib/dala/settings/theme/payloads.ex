defmodule Dala.Settings.Theme.Payloads do
  @moduledoc """
  PubSub publication transforms for `Dala.Settings.Theme`.

  Typed channels have no runtime formatting layer — whatever these functions
  return goes over the wire verbatim — so keys are camelCase to match the
  generated TypeScript payload types. Every payload carries `ownerId` so a
  connected client can filter the broadcast to "mine + global" itself: the
  topic is a single shared `"settings"` (mirroring the shared `"sessions"`
  lobby), not a per-user topic.
  """

  def summary(%Ash.Notifier.Notification{data: theme}) do
    %{
      id: theme.id,
      ownerId: theme.owner_id,
      name: theme.name,
      base: theme.base,
      builtin: theme.builtin,
      tokens: theme.tokens,
      insertedAt: theme.inserted_at,
      updatedAt: theme.updated_at
    }
  end

  def deleted(%Ash.Notifier.Notification{data: theme}) do
    %{id: theme.id, ownerId: theme.owner_id}
  end

  def summary_fields do
    [
      id: [type: :uuid, allow_nil?: false],
      ownerId: [type: :uuid, allow_nil?: false],
      name: [type: :string, allow_nil?: false],
      base: [type: :atom, constraints: [one_of: [:light, :dark]], allow_nil?: false],
      builtin: [type: :boolean, allow_nil?: false],
      tokens: [type: :map, allow_nil?: false],
      insertedAt: [type: :utc_datetime_usec, allow_nil?: false],
      updatedAt: [type: :utc_datetime_usec, allow_nil?: false]
    ]
  end

  def deleted_fields do
    [
      id: [type: :uuid, allow_nil?: false],
      ownerId: [type: :uuid, allow_nil?: false]
    ]
  end
end
