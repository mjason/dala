defmodule Dala.Platform do
  @moduledoc false

  def windows?, do: match?({:win32, :nt}, :os.type())

  def chmod(path, mode) do
    if windows?(), do: :ok, else: File.chmod(path, mode)
  end

  def chmod!(path, mode) do
    case chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "chmod", path: path
    end
  end

  def kill_process_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    {command, args} =
      if windows?() do
        {"taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"]}
      else
        {"kill", ["-KILL", Integer.to_string(os_pid)]}
      end

    _ = System.cmd(command, args, stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end
end
