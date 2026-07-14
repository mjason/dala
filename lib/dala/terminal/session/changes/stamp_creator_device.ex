defmodule Dala.Terminal.Session.Changes.StampCreatorDevice do
  @moduledoc """
  Seeds PTY size ownership at creation: the CREATING device (optional
  `device_id` argument) becomes the remembered `size_owner_device` before
  anyone can attach.

  This closes an adoption race in the first-attach fallback: a phone
  creates a session and an idle desktop tab auto-mounts it off the
  session_created broadcast — whichever attaches first used to adopt, so
  the creating phone often ended up a follower of a wide desktop grid.

  Sessions created without a device id (legacy clients, raw API callers)
  stamp nothing and keep the first-attach adoption fallback. Blank ids
  never stamp: the channel maps "" to nil on join, so a persisted "" would
  ghost-lock the session for every real device.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    with device when is_binary(device) <- Ash.Changeset.get_argument(changeset, :device_id),
         trimmed when trimmed != "" <- String.trim(device) do
      Ash.Changeset.force_change_attribute(changeset, :size_owner_device, trimmed)
    else
      _none -> changeset
    end
  end
end
