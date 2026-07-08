defmodule Dala.Terminal.Session.Changes.SetDefaults do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    shell =
      argument_or_nil(changeset, :shell) ||
        System.get_env("SHELL") ||
        "/bin/bash"

    cwd = argument_or_nil(changeset, :cwd) || System.user_home() || "/"
    name = argument_or_nil(changeset, :name) || Path.basename(shell)

    changeset
    |> Ash.Changeset.force_change_attribute(:shell, shell)
    |> Ash.Changeset.force_change_attribute(:cwd, cwd)
    |> Ash.Changeset.force_change_attribute(:name, name)
  end

  defp argument_or_nil(changeset, name) do
    case Ash.Changeset.get_argument(changeset, name) do
      value when value in [nil, ""] -> nil
      value -> String.trim(value)
    end
  end
end
