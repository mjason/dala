defmodule Dala.Terminal.Session.Changes.SetDefaults do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    parent = parent_session(changeset)

    shell = argument_or_nil(changeset, :shell) || default_shell()

    cwd =
      argument_or_nil(changeset, :cwd) || (parent && parent.cwd) || System.user_home() || "/"

    name =
      argument_or_nil(changeset, :name) ||
        if(parent, do: attached_shell_name(parent), else: default_name(cwd))

    changeset
    |> Ash.Changeset.force_change_attribute(:shell, shell)
    |> Ash.Changeset.force_change_attribute(:cwd, cwd)
    |> Ash.Changeset.force_change_attribute(:name, name)
    |> then(fn changeset ->
      # Tabs of tabs would have nowhere to render: attach to the root instead.
      if parent,
        do: Ash.Changeset.force_change_attribute(changeset, :parent_id, parent.id),
        else: changeset
    end)
    |> then(fn changeset ->
      # A tab that exits should close, not linger as a dead one.
      if parent,
        do: Ash.Changeset.force_change_attribute(changeset, :ephemeral, true),
        else: changeset
    end)
  end

  defp parent_session(changeset) do
    case Ash.Changeset.get_attribute(changeset, :parent_id) do
      nil ->
        nil

      parent_id ->
        case Dala.Terminal.get_session(parent_id) do
          {:ok, %{parent_id: nil} = parent} -> parent
          {:ok, %{parent_id: root_id}} -> parent_session_by_id(root_id)
          {:error, _error} -> nil
        end
    end
  end

  defp parent_session_by_id(id) do
    case Dala.Terminal.get_session(id) do
      {:ok, root} -> root
      {:error, _error} -> nil
    end
  end

  # Tabs are told apart by name, so "shell", "shell 2", "shell 3"… per parent.
  defp attached_shell_name(parent) do
    taken =
      parent.id
      |> Dala.Terminal.Session.Changes.CloseAttachedShells.attached_shells()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    if MapSet.member?(taken, "shell") do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find(fn suffix -> not MapSet.member?(taken, "shell #{suffix}") end)
      |> then(&"shell #{&1}")
    else
      "shell"
    end
  end

  defp argument_or_nil(changeset, name) do
    case Ash.Changeset.get_argument(changeset, name) do
      value when value in [nil, ""] -> nil
      value -> String.trim(value)
    end
  end

  defp default_shell do
    case :os.type() do
      {:win32, :nt} ->
        System.find_executable("pwsh") ||
          System.find_executable("powershell") ||
          System.get_env("ComSpec") ||
          System.get_env("WINDIR", "C:\\Windows")
          |> Path.join("System32/WindowsPowerShell/v1.0/powershell.exe")

      _ ->
        System.get_env("SHELL") || "/bin/bash"
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
