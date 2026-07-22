defmodule Dala.Terminal.Shell do
  @moduledoc """
  Platform shell defaults and the small integrations Dala injects at spawn.
  """

  def default_shell(os_type \\ :os.type(), finder \\ &System.find_executable/1)

  def default_shell({:win32, _}, finder) do
    shell =
      Enum.find_value(["pwsh.exe", "powershell.exe"], finder) ||
        System.get_env("COMSPEC") || finder.("cmd.exe") || "cmd.exe"

    normalize_executable(shell, {:win32, :nt})
  end

  def default_shell(_os_type, _finder) do
    System.get_env("SHELL") || "/bin/bash"
  end

  def spawn_options(shell, os_type \\ :os.type())

  def spawn_options(shell, {:win32, _}) do
    case executable_name(shell) do
      name when name in ["pwsh", "powershell"] ->
        script = Path.join(:code.priv_dir(:dala), "windows/dala-powershell.ps1")
        quoted = String.replace(script, "'", "''")
        [args: ["-NoExit", "-Command", ". '#{quoted}'"], env: []]

      "cmd" ->
        # $E is ESC and ESC\\ terminates OSC; $P then restores the familiar
        # current-directory prompt after reporting it to the holder.
        [
          args: ["/D", "/Q", "/K", "rem"],
          env: [{"PROMPT", "$E]7;file://localhost/$P$E\\$P$G"}]
        ]

      _other ->
        [args: [], env: []]
    end
  end

  def spawn_options(_shell, _os_type), do: [args: [], env: []]

  @doc "Uses the native separator for Windows executable paths."
  def normalize_executable(path, os_type \\ :os.type())
  def normalize_executable(path, {:win32, _}), do: String.replace(path, "/", "\\")
  def normalize_executable(path, _os_type), do: path

  defp executable_name(path) do
    path
    |> String.replace("\\", "/")
    |> Path.basename()
    |> String.downcase()
    |> String.replace_suffix(".exe", "")
    |> String.replace_suffix(".cmd", "")
    |> String.replace_suffix(".bat", "")
  end
end
