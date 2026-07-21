defmodule Dala.TestPlatform do
  @moduledoc false

  def windows?, do: match?({:win32, _}, :os.type())

  def normalize_path(path) do
    Dala.Paths.comparison_key(path)
  end

  def same_path?(left, right), do: normalize_path(left) == normalize_path(right)

  def shell do
    if windows?() do
      (System.find_executable("cmd.exe") || "cmd.exe")
      |> Dala.Terminal.Shell.normalize_executable()
    else
      "/bin/bash"
    end
  end

  def echo(value), do: "echo #{value}\r"

  def set_env(name, value) do
    if windows?(), do: "set \"#{name}=#{value}\"\r", else: "#{name}=#{value}\r"
  end

  def echo_env(prefix, name) do
    if windows?(), do: "echo #{prefix}%#{name}%\r", else: "echo #{prefix}$#{name}\r"
  end

  def columns do
    if windows?(),
      do: "powershell.exe -NoProfile -Command \"[Console]::WindowWidth\"\r",
      else: "tput cols\r"
  end

  def node_eval_command(source) when is_binary(source) do
    if windows?(),
      do: windows_node_command(source),
      else: "node -e #{shell_quote(source)}"
  end

  def node_script_command(path) when is_binary(path) do
    if windows?() do
      encoded_path = Base.encode64(path)
      windows_node_command("require(Buffer.from('#{encoded_path}','base64').toString('utf8'))")
    else
      "node #{shell_quote(path)}"
    end
  end

  defp windows_node_command(source) do
    script = """
      $native = '[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int handle); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr handle, out uint mode); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr handle, uint mode);'
      Add-Type -MemberDefinition $native -Name NativeMethods -Namespace Dala
      $handle = [Dala.NativeMethods]::GetStdHandle(-11)
      [uint32]$mode = 0
      if (-not [Dala.NativeMethods]::GetConsoleMode($handle, [ref]$mode)) {
        throw "GetConsoleMode failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
      }
      if (-not [Dala.NativeMethods]::SetConsoleMode($handle, $mode -bor 4)) {
        throw "SetConsoleMode failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
      }
    """

    encoded_script =
      script
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    wrapped_source =
      "require('node:child_process').execFileSync('powershell.exe'," <>
        "['-NoProfile','-NonInteractive','-EncodedCommand','#{encoded_script}']," <>
        "{stdio:'inherit'});" <> source

    encoded_source = Base.encode64(wrapped_source)

    "node.exe -e \"eval(Buffer.from('#{encoded_source}','base64').toString('utf8'))\""
  end

  defp shell_quote(value), do: "'#{String.replace(value, "'", "'\\''")}'"
end
