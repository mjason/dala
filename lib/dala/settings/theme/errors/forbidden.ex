defmodule Dala.Settings.Theme.Errors.Forbidden do
  @moduledoc """
  Raised when a caller tries to mutate a theme it does not own, or any
  built-in preset. The whole app runs `authorize? false` (isolation is manual
  scoping, mirroring `Dala.Settings.Speech`), so there is no policy to lean on:
  the ownership/built-in guard adds THIS error to the changeset instead.

  `class: :forbidden` makes Ash surface the failure as an `Ash.Error.Forbidden`
  (a 403-shaped error over RPC), not a plain validation error.
  """

  use Splode.Error, fields: [:message], class: :forbidden

  def message(%{message: message}) when is_binary(message), do: message
  def message(_error), do: "forbidden"
end
