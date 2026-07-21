defmodule Dala.Terminal.Session.Changes.SetDefaults do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    shell =
      argument_or_nil(changeset, :shell) ||
        Dala.Terminal.Shell.default_shell()

    cwd = argument_or_nil(changeset, :cwd) || System.user_home() || "/"
    name = argument_or_nil(changeset, :name) || default_name(cwd)

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

  defp default_name(cwd) do
    base =
      if Path.expand(cwd) == Path.expand(System.user_home() || "") do
        "Terminal"
      else
        case Path.basename(Path.expand(cwd)) do
          value when value in ["", "/", "."] -> "Terminal"
          value -> value
        end
      end

    base = String.slice(base, 0, 180)
    names = Dala.Terminal.list_sessions!() |> Enum.map(& &1.name) |> MapSet.new()

    if MapSet.member?(names, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find(fn suffix -> not MapSet.member?(names, "#{base} #{suffix}") end)
      |> then(&"#{base} #{&1}")
    else
      base
    end
  rescue
    _error -> "Terminal"
  end
end
